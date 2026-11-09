#!/bin/bash
#
# XUI ONE — Aplicador de patches
# https://github.com/cunninghambr/xuione
#
# Uso:
#   sudo ./apply-patches.sh                    (menu interativo)
#   sudo ./apply-patches.sh cloudflare         (aplica o fix Cloudflare)
#   sudo ./apply-patches.sh epg                (aplica o fix de EPG)
#   sudo ./apply-patches.sh all                (aplica os dois)
#   sudo ./apply-patches.sh status             (só mostra o estado atual)
#
# Idempotente: pode rodar quantas vezes quiser, ele detecta o que já está
# aplicado e não duplica nada. Faz backup antes de alterar nginx.conf.
#
set -uo pipefail

XUI_HOME="/home/xui"
NGINX_CONF="$XUI_HOME/bin/nginx/conf/nginx.conf"
REALIP_CONF="$XUI_HOME/bin/nginx/conf/realip_cloudflare.conf"
NGINX_BIN="$XUI_HOME/bin/nginx/sbin/nginx"
PHP_BIN="$XUI_HOME/bin/php/bin/php"
EPG_PATCH="$XUI_HOME/crons/epg_patch.php"
CRONTAB_ROOT="/var/spool/cron/crontabs/root"
BACKUP_DIR="/root/xui-patches-backup"

# Diretório onde este script e os arquivos dos patches vivem.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_IPS_FILE="$SCRIPT_DIR/patches/cloudflare-fix/cloudflare-ips.conf"
EPG_SRC_FILE="$SCRIPT_DIR/patches/epg-instant-fix/epg_patch.php"

# Permite rodar de dentro de patches/ também.
[ -f "$CF_IPS_FILE" ] || CF_IPS_FILE="$SCRIPT_DIR/cloudflare-fix/cloudflare-ips.conf"
[ -f "$EPG_SRC_FILE" ] || EPG_SRC_FILE="$SCRIPT_DIR/epg-instant-fix/epg_patch.php"

# Se este script foi baixado sozinho (sem o repo ao lado), busca os payloads
# direto do repositorio. Assim ele funciona como instalador de arquivo único.
RAW_BASE="https://raw.githubusercontent.com/cunninghambr/xuione/main"

fetch_payload() {
    local url="$1" dest="$2"
    [ -s "$dest" ] && return 0
    info "Baixando $(basename "$dest")..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" 2>/dev/null
    else
        wget -qO "$dest" "$url" 2>/dev/null
    fi
    [ -s "$dest" ]
}

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"
C_CYAN="\033[1;36m"; C_YELLOW="\033[1;33m"

info()  { echo -e "${C_CYAN}[*]${C_RESET} $1"; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $1"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
error() { echo -e "${C_RED}[!]${C_RESET} $1"; }

# grep -c imprime 0 e ainda assim retorna exit 1 quando nao ha match.
# Este helper devolve sempre um inteiro limpo (nunca "0\n0").
count_matches() {
    local n
    n=$(grep -c -- "$1" "$2" 2>/dev/null)
    echo "${n:-0}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Este script precisa ser executado como root (use sudo)."
        exit 1
    fi
}

require_install() {
    if [ ! -d "$XUI_HOME" ]; then
        error "XUI nao encontrado em $XUI_HOME. Instale o painel primeiro."
        exit 1
    fi
}

backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    mkdir -p "$BACKUP_DIR"
    local dest="$BACKUP_DIR/$(echo "$f" | tr '/' '_').$(date +%Y%m%d-%H%M%S)"
    cp -p "$f" "$dest" && ok "Backup: $dest"
}

mysql_root() {
    # Tenta socket sem senha (padrao em instalacao limpa do XUI).
    if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
        mysql -u root "$@"
        return
    fi
    warn "root do MySQL exige senha. Rode manualmente:"
    echo "    mysql -u root -p xui -e \"UPDATE settings SET cloudflare = 1, allow_cdn_access = 1;\""
    return 1
}

cf_applied() {
    local header db_flag ips
    header=$(count_matches "real_ip_header CF-Connecting-IP;" "$NGINX_CONF")
    db_flag=$(mysql -u root -N -B -e "SELECT cloudflare, allow_cdn_access FROM xui.settings;" 2>/dev/null | awk '{print $1$2}')
    ips=$(count_matches "set_real_ip_from" "$REALIP_CONF")
    [ "$header" -ge 1 ] && [ "$db_flag" = "11" ] && [ "$ips" -ge 1 ]
}

epg_applied() {
    [ -f "$EPG_PATCH" ] && crontab -l 2>/dev/null | grep -q "epg_patch.php"
}

show_status() {
    echo ""
    echo -e "${C_CYAN}Estado dos patches${C_RESET}"
    echo "---------------------------------------------------"

    local h d i
    h=$(count_matches "real_ip_header CF-Connecting-IP;" "$NGINX_CONF")
    d=$(mysql -u root -N -B -e "SELECT cloudflare, allow_cdn_access FROM xui.settings;" 2>/dev/null | awk '{print $1$2}')
    i=$(count_matches "set_real_ip_from" "$REALIP_CONF")
    echo -n "  Cloudflare Fix : "
    if [ "$h" -ge 1 ] && [ "$d" = "11" ] && [ "$i" -ge 1 ]; then
        echo -e "${C_GREEN}APLICADO${C_RESET} (header ok, DB flags ok, $i faixas de IP)"
    else
        echo -e "${C_YELLOW}PENDENTE${C_RESET} (header=$h, db_flags=${d:-?}, faixas=$i)"
    fi

    echo -n "  EPG Instant Fix: "
    if epg_applied; then
        echo -e "${C_GREEN}APLICADO${C_RESET} (arquivo + cron de 1 min)"
    else
        [ -f "$EPG_PATCH" ] && local f="arquivo ok, " || local f="arquivo NAO copiado, "
        echo -e "${C_YELLOW}PENDENTE${C_RESET} (${f}cron ausente)"
    fi
    echo ""
}

apply_cloudflare() {
    info "Aplicando Cloudflare Fix..."

    if [ ! -f "$NGINX_CONF" ]; then
        error "nginx.conf nao encontrado em $NGINX_CONF"
        return 1
    fi
    if [ ! -f "$CF_IPS_FILE" ]; then
        fetch_payload "$RAW_BASE/patches/cloudflare-fix/cloudflare-ips.conf" "$CF_IPS_FILE" || true
    fi
    if [ ! -f "$CF_IPS_FILE" ]; then
        error "Lista de IPs nao encontrada em $CF_IPS_FILE"
        return 1
    fi

    # 1) Flags no banco: sem isso o cron root_signals.php esvazia o arquivo.
    info "1/4 Ativando cloudflare/allow_cdn_access no banco..."
    if mysql_root -e "UPDATE xui.settings SET cloudflare = 1, allow_cdn_access = 1;"; then
        ok "Flags do banco definidas"
    else
        warn "Pulei as flags do banco (resolva manualmente e rode de novo)"
    fi

    # 2) real_ip_header
    info "2/4 Ajustando real_ip_header no nginx.conf..."
    if grep -q "real_ip_header CF-Connecting-IP;" "$NGINX_CONF"; then
        ok "real_ip_header ja aponta para CF-Connecting-IP"
    else
        backup_file "$NGINX_CONF"
        sed -i 's/^\([[:space:]]*\)real_ip_header[[:space:]].*/\1real_ip_header CF-Connecting-IP;/' "$NGINX_CONF"
        if grep -q "real_ip_header CF-Connecting-IP;" "$NGINX_CONF"; then
            ok "real_ip_header trocado para CF-Connecting-IP"
        else
            error "Nao encontrei a diretiva real_ip_header para substituir"
            return 1
        fi
    fi

    # 3) faixas de IP
    info "3/4 Preenchendo realip_cloudflare.conf..."
    if [ "$(count_matches 'set_real_ip_from' "$REALIP_CONF")" -gt 0 ]; then
        ok "realip_cloudflare.conf ja preenchido ($(count_matches 'set_real_ip_from' "$REALIP_CONF") faixas)"
    else
        backup_file "$REALIP_CONF"
        cp "$CF_IPS_FILE" "$REALIP_CONF"
        chmod 550 "$REALIP_CONF"
        chown xui:xui "$REALIP_CONF" 2>/dev/null || true
        ok "realip_cloudflare.conf preenchido e com permissoes corretas"
        warn "Reveja a lista em https://www.cloudflare.com/ips/ de tempos em tempos"
    fi

    # 4) teste + reload
    info "4/4 Testando sintaxe e recarregando nginx..."
    local tlog="/tmp/xui-nginx-t.log"
    local test_ok=0
    if command -v sudo >/dev/null 2>&1 && id xui >/dev/null 2>&1; then
        sudo -u xui "$NGINX_BIN" -t >"$tlog" 2>&1 && test_ok=1
    else
        # sem sudo ou sem o usuario xui (ex. container): tenta direto
        "$NGINX_BIN" -t >"$tlog" 2>&1 && test_ok=1
    fi

    if [ "$test_ok" -eq 1 ]; then
        ok "Sintaxe do nginx OK"
        if "$NGINX_BIN" -s reload >/dev/null 2>&1; then
            ok "nginx recarregado"
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl restart xuione >/dev/null 2>&1 && ok "servico xuione reiniciado" \
                || warn "Falha ao recarregar. Rode: $NGINX_BIN -s reload"
        else
            warn "Falha ao recarregar o nginx. Rode: $NGINX_BIN -s reload"
        fi
    else
        error "Teste do nginx falhou! Nao recarreguei. Log:"
        tail -5 "$tlog"
        warn "Backups em $BACKUP_DIR — restaure se necessario"
        return 1
    fi

    ok "Cloudflare Fix aplicado"
    echo ""
    warn "Recomendado: em Servers -> Advanced use so portas proxiadas pelo Cloudflare"
    echo "    HTTPS: 443, 2053, 2083, 2087, 2096, 8443"
    echo "    HTTP : 80, 8080, 8880, 2052, 2082, 2086, 2095"
    echo "    Portas fora dessa lista (ex. 8000) expoem o servidor de origem."
    echo ""
}

apply_epg() {
    info "Aplicando EPG Instant Fix..."

    if [ ! -f "$EPG_SRC_FILE" ]; then
        fetch_payload "$RAW_BASE/patches/epg-instant-fix/epg_patch.php" "$EPG_SRC_FILE" || true
    fi
    if [ ! -f "$EPG_SRC_FILE" ]; then
        error "epg_patch.php nao encontrado em $EPG_SRC_FILE"
        return 1
    fi
    if [ ! -d "$XUI_HOME/crons" ]; then
        error "Diretorio $XUI_HOME/crons nao existe"
        return 1
    fi
    if [ ! -x "$PHP_BIN" ]; then
        error "PHP do XUI nao encontrado em $PHP_BIN"
        return 1
    fi

    info "1/3 Copiando epg_patch.php para $XUI_HOME/crons/..."
    backup_file "$EPG_PATCH"
    cp "$EPG_SRC_FILE" "$EPG_PATCH"
    chown root:root "$EPG_PATCH" 2>/dev/null || true
    chmod 644 "$EPG_PATCH"
    "$PHP_BIN" -l "$EPG_PATCH" >/dev/null 2>&1 && ok "Sintaxe PHP OK" || warn "Nao consegui validar a sintaxe com o PHP do XUI"

    info "2/3 Adicionando ao crontab do root (a cada minuto)..."
    local cron_line="* * * * * $PHP_BIN $EPG_PATCH > /dev/null 2>&1"
    local locked=0
    if [ -f "$CRONTAB_ROOT" ] && lsattr "$CRONTAB_ROOT" 2>/dev/null | grep -q "^....i"; then
        chattr -i "$CRONTAB_ROOT" 2>/dev/null && locked=1
    fi
    if crontab -l 2>/dev/null | grep -qF "epg_patch.php"; then
        ok "Cron do epg_patch ja existe"
    elif ! command -v crontab >/dev/null 2>&1; then
        error "Comando 'crontab' nao encontrado. Adicione manualmente ao crontab do root:"
        echo "    $cron_line"
        [ "$locked" -eq 1 ] && chattr +i "$CRONTAB_ROOT" 2>/dev/null
        return 1
    else
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        if crontab -l 2>/dev/null | grep -qF "epg_patch.php"; then
            ok "Cron adicionado e confirmado"
        else
            error "Falha ao gravar o crontab. Adicione manualmente:"
            echo "    $cron_line"
            [ "$locked" -eq 1 ] && chattr +i "$CRONTAB_ROOT" 2>/dev/null
            return 1
        fi
    fi
    [ "$locked" -eq 1 ] && chattr +i "$CRONTAB_ROOT" 2>/dev/null

    info "3/3 Rodando o patch uma vez para gerar os caches faltantes..."
    if "$PHP_BIN" "$EPG_PATCH"; then
        ok "Execucao inicial concluida"
    else
        warn "A execucao retornou erro (verifique o acesso ao MySQL via socket)"
    fi

    ok "EPG Instant Fix aplicado — novos EPGs aparecem em ate 1 minuto"
    echo ""
}

usage() {
    echo ""
    echo "Uso: $0 [cloudflare|epg|all|status]"
    echo ""
    echo "  cloudflare   Corrige login em loop atras do Cloudflare"
    echo "  epg          Gera cache de EPG na hora (em vez de esperar a meia-noite)"
    echo "  all          Aplica os dois"
    echo "  status       Mostra o que ja esta aplicado"
    echo ""
    exit 1
}

menu() {
    echo ""
    echo -e "${C_CYAN}===============================================${C_RESET}"
    echo -e "${C_CYAN}   XUI ONE - Patches de melhoria${C_RESET}"
    echo -e "${C_CYAN}   github.com/cunninghambr/xuione${C_RESET}"
    echo -e "${C_CYAN}===============================================${C_RESET}"
    show_status
    echo "Selecione o que aplicar:"
    echo "  1) Cloudflare Fix   (login em loop atras do Cloudflare)"
    echo "  2) EPG Instant Fix  (EPG na hora, sem esperar a meia-noite)"
    echo "  3) Os dois"
    echo "  4) Apenas mostrar status"
    echo "  0) Sair"
    echo ""
    while true; do
        read -rp "Opcao [0-4]: " opt
        case "$opt" in
            1) apply_cloudflare; exit 0 ;;
            2) apply_epg; exit 0 ;;
            3) apply_cloudflare; apply_epg; exit 0 ;;
            4) exit 0 ;;
            0) exit 0 ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

require_root
require_install

case "${1:-}" in
    cloudflare) apply_cloudflare ;;
    epg)        apply_epg ;;
    all)        apply_cloudflare; apply_epg ;;
    status)     show_status ;;
    "")         menu ;;
    *)          usage ;;
esac
