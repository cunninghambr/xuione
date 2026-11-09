#!/bin/bash
#
# XUI ONE - Aplicador de patches de melhoria
# https://github.com/cunninghambr/xuione
#
# Uso:
#   ./patchxui.sh status            (mostra o que esta aplicado)
#   ./patchxui.sh epg               (EPG Instant Fix)
#   ./patchxui.sh cloudflare        (Cloudflare Fix)
#   ./patchxui.sh all               (os dois)
#
# Opcoes:
#   -y, --yes    nao pedir confirmacao
#   -f, --force  reescrever arquivos mesmo se ja configurados
#
# Pode ser chamado depois de cada instalacao/atualizacao: e idempotente
# (rodar duas vezes nao duplica nada).
#
# Variaveis de ambiente (usadas tambem para testes):
#   XUI_ROOT, NGINX_CONF, REALIP_CONF, NGINX_BIN, PHP_BIN,
#   CRONS_DIR, EPG_PATCH, CRONTAB_FILE, MYSQL_CMD, DRY_RUN
#
set -uo pipefail

XUI_ROOT="${XUI_ROOT:-/home/xui}"
NGINX_CONF="${NGINX_CONF:-$XUI_ROOT/bin/nginx/conf/nginx.conf}"
REALIP_CONF="${REALIP_CONF:-$XUI_ROOT/bin/nginx/conf/realip_cloudflare.conf}"
NGINX_BIN="${NGINX_BIN:-$XUI_ROOT/bin/nginx/sbin/nginx}"
PHP_BIN="${PHP_BIN:-$XUI_ROOT/bin/php/bin/php}"
CRONS_DIR="${CRONS_DIR:-$XUI_ROOT/crons}"
EPG_PATCH="${EPG_PATCH:-$CRONS_DIR/epg_patch.php}"
CRONTAB_FILE="${CRONTAB_FILE:-/var/spool/cron/crontabs/root}"
MYSQL_CMD="${MYSQL_CMD:-mysql -u root xui}"
DRY_RUN="${DRY_RUN:-0}"

RAW_BASE="https://raw.githubusercontent.com/cunninghambr/xuione/main"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"
C_CYAN="\033[1;36m"; C_YELLOW="\033[1;33m"

info()  { echo -e "${C_CYAN}[*]${C_RESET} $1"; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $1"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
error() { echo -e "${C_RED}[!]${C_RESET} $1"; }

run() {
    if [ "$DRY_RUN" = "1" ]; then echo "    [dry-run] $*"; return 0; fi
    "$@"
}

shellrun() {
    if [ "$DRY_RUN" = "1" ]; then echo "    [dry-run] $1"; return 0; fi
    bash -c "$1"
}

CONFIRM_ALL=0
FORCE=0
CMD=""

usage() {
    echo ""
    echo "Uso: $0 [status|epg|cloudflare|all] [-y] [-f]"
    echo ""
    echo "  status       mostra o estado atual dos patches"
    echo "  epg          aplica o EPG Instant Fix"
    echo "  cloudflare   aplica o Cloudflare Fix"
    echo "  all          aplica os dois"
    echo "  -y, --yes    nao pedir confirmacao"
    echo "  -f, --force  reescrever mesmo se ja configurado"
    echo ""
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        status|epg|cloudflare|all) CMD="$arg" ;;
        -y|--yes)   CONFIRM_ALL=1 ;;
        -f|--force) FORCE=1 ;;
        -h|--help)  usage ;;
        *) error "Argumento invalido: $arg"; usage ;;
    esac
done

[ -z "$CMD" ] && usage

require_xui() {
    if [ ! -d "$XUI_ROOT" ]; then
        error "Nenhuma instalacao do XUI encontrada em $XUI_ROOT."
        error "Instale o painel antes de aplicar os patches."
        exit 1
    fi
}

require_root() {
    if [ "${XUI_ALLOW_NONROOT:-0}" = "1" ]; then
        warn "Checagem de root desativada (XUI_ALLOW_NONROOT=1) - apenas para testes."
        return 0
    fi
    if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        error "Execute como root (use sudo)."
        exit 1
    fi
}

ask() {
    local rPrompt="$1" rDefault="$2"
    if [ "$CONFIRM_ALL" = "1" ] || [ "$DRY_RUN" = "1" ]; then return 0; fi
    local rAnswer
    read -rp "$rPrompt [$rDefault]: " rAnswer
    rAnswer="${rAnswer:-$rDefault}"
    [[ "$rAnswer" =~ ^[YySs]$ ]]
}

##################################################
# CLOUDFLARE FIX                                 #
##################################################

cf_flags_status() {
    [ "$DRY_RUN" = "1" ] && { echo "desconhecido (dry-run)"; return; }
    local rVal
    rVal=$(bash -c "$MYSQL_CMD -N -B -e 'SELECT CONCAT(cloudflare, \"/\", allow_cdn_access) FROM settings LIMIT 1;'" 2>/dev/null)
    echo "${rVal:-desconhecido}"
}

patch_cloudflare() {
    info "Cloudflare Fix"

    # 1) Flags no banco. Sem isso o cron root_signals.php esvazia o
    #    realip_cloudflare.conf no minuto seguinte.
    info "Ativando cloudflare/allow_cdn_access no banco..."
    if ! shellrun "$MYSQL_CMD -e \"UPDATE settings SET cloudflare = 1, allow_cdn_access = 1;\""; then
        error "Falha ao atualizar o banco. Rode como root (auth por unix_socket)."
        return 1
    fi
    ok "Flags do banco ajustadas."

    # 2) real_ip_header no nginx.conf
    if [ ! -f "$NGINX_CONF" ]; then
        error "nginx.conf nao encontrado em $NGINX_CONF"
        return 1
    fi

    if grep -qE '^[[:space:]]*real_ip_header[[:space:]]+CF-Connecting-IP;' "$NGINX_CONF"; then
        ok "real_ip_header ja esta como CF-Connecting-IP."
    else
        if ! grep -qE '^[[:space:]]*real_ip_header' "$NGINX_CONF"; then
            error "Nao encontrei a diretiva real_ip_header em $NGINX_CONF"
            error "Ajuste manualmente: real_ip_header CF-Connecting-IP;"
            return 1
        fi
        local rBackup
        rBackup="$NGINX_CONF.bak-$(date +%Y%m%d%H%M%S)"
        if [ "$DRY_RUN" != "1" ]; then
            if ! cat "$NGINX_CONF" > "$rBackup" 2>/dev/null || ! cmp -s "$NGINX_CONF" "$rBackup"; then
                error "Falha ao criar backup em $rBackup - abortando sem alterar nginx.conf."
                return 1
            fi
        else
            echo "    [dry-run] backup em $rBackup"
        fi
        info "Backup: $rBackup"
        if run sed -i -E 's|^([[:space:]]*)real_ip_header[[:space:]]+.*;|\1real_ip_header CF-Connecting-IP;|' "$NGINX_CONF"; then
            ok "real_ip_header trocado para CF-Connecting-IP."
        else
            error "Falha ao editar nginx.conf."
            return 1
        fi
    fi

    # 3) realip_cloudflare.conf com os ranges da Cloudflare
    if [ -s "$REALIP_CONF" ] && ! grep -q "set_real_ip_from" "$REALIP_CONF" 2>/dev/null; then
        warn "realip_cloudflare.conf tem conteudo inesperado; sera reescrito."
        FORCE=1
    fi

    if [ -s "$REALIP_CONF" ] && [ "$FORCE" != "1" ]; then
        ok "realip_cloudflare.conf ja populado ($(grep -c 'set_real_ip_from' "$REALIP_CONF") ranges)."
    else
        info "Baixando ranges atuais da Cloudflare..."
        local rRanges=""
        if command -v curl >/dev/null 2>&1; then
            rRanges=$(curl -fsS --max-time 15 https://api.cloudflare.com/client/v4/ips 2>/dev/null \
                | grep -oE '"[0-9a-fA-F:.]+/[0-9]{1,3}"' | tr -d '"')
        fi
        if [ -z "$rRanges" ]; then
            warn "API da Cloudflare indisponivel; usando lista embutida."
            rRanges="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
        fi

        local rTmp
        rTmp="$(dirname "$REALIP_CONF")/.realip.tmp.$$"
        {
            echo "# Cloudflare IP ranges - gerado por patchxui.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "# Fonte: https://api.cloudflare.com/client/v4/ips"
            echo "# Atencao: a diretiva do header real fica somente em nginx.conf."
            echo "$rRanges" | while read -r rCidr; do
                [ -n "$rCidr" ] && echo "set_real_ip_from $rCidr;"
            done
        } > "$rTmp" 2>/dev/null || {
            error "Falha ao escrever $rTmp"
            return 1
        }
        run mv "$rTmp" "$REALIP_CONF"
        run chmod 550 "$REALIP_CONF"
        if id xui >/dev/null 2>&1; then run chown xui:xui "$REALIP_CONF"; fi
        ok "realip_cloudflare.conf populado ($(grep -c 'set_real_ip_from' "$REALIP_CONF" 2>/dev/null) ranges)."
    fi

    # 4) Testar e recarregar nginx
    if [ "$DRY_RUN" = "1" ]; then
        info "[dry-run] pularia teste/recarga do nginx."
        return 0
    fi

    info "Testando configuracao do nginx..."
    if sudo -u xui "$NGINX_BIN" -t 2>/dev/null || "$NGINX_BIN" -t 2>/dev/null; then
        if "$NGINX_BIN" -s reload 2>/dev/null; then
            ok "nginx recarregado."
        else
            warn "nginx -t passou, mas o reload falhou. Rode: $NGINX_BIN -s reload"
        fi
    else
        error "nginx -t falhou. Restaurando backup do nginx.conf."
        local rLast rOk=0
        rLast=$(ls -1t "$NGINX_CONF".bak-* 2>/dev/null | head -1)
        if [ -n "$rLast" ] && [ -f "$rLast" ]; then
            # cat > verifica escrita de verdade (cp -a pode falhar em
            # permissoes/atributos e ainda assim parecer que copiou)
            if cat "$rLast" > "$NGINX_CONF" 2>/dev/null; then
                if cmp -s "$rLast" "$NGINX_CONF"; then rOk=1; fi
            fi
            if [ "$rOk" = "1" ]; then
                warn "nginx.conf restaurado de $rLast"
            else
                error "NAO foi possivel restaurar o nginx.conf automaticamente."
                error "Restaure manualmente: cat '$rLast' > '$NGINX_CONF'"
            fi
        else
            error "Nenhum backup encontrado para restaurar $NGINX_CONF"
        fi
        return 1
    fi
}

##################################################
# EPG INSTANT FIX                                #
##################################################

patch_epg() {
    info "EPG Instant Fix"

    if ! mkdir -p "$CRONS_DIR" 2>/dev/null; then
        error "Nao foi possivel criar $CRONS_DIR"
        return 1
    fi

    # 1) Instalar o epg_patch.php
    local rSrc=""
    for rCand in "$SELF_DIR/patches/epg-instant-fix/epg_patch.php" \
                 "$SELF_DIR/epg_patch.php"; do
        [ -f "$rCand" ] && rSrc="$rCand" && break
    done

    if [ -n "$rSrc" ]; then
        run cp -f "$rSrc" "$EPG_PATCH"
        ok "epg_patch.php copiado de $rSrc"
    else
        info "Baixando epg_patch.php do repositorio..."
        if command -v wget >/dev/null 2>&1; then
            run wget -qO "$EPG_PATCH" "$RAW_BASE/patches/epg-instant-fix/epg_patch.php" || {
                error "Falha no download do epg_patch.php"; return 1; }
        elif command -v curl >/dev/null 2>&1; then
            run curl -fsSL -o "$EPG_PATCH" "$RAW_BASE/patches/epg-instant-fix/epg_patch.php" || {
                error "Falha no download do epg_patch.php"; return 1; }
        else
            error "Sem wget/curl e sem copia local do epg_patch.php."
            return 1
        fi
        ok "epg_patch.php baixado."
    fi

    run chmod 644 "$EPG_PATCH"
    if id root >/dev/null 2>&1; then run chown root:root "$EPG_PATCH"; fi

    # 2) Entrada no cron do root (XUI trava a crontab com chattr +i)
    local rLine="* * * * * $PHP_BIN $EPG_PATCH > /dev/null 2>&1"

    if [ ! -f "$CRONTAB_FILE" ]; then
        warn "Crontab do root nao encontrada em $CRONTAB_FILE; pulando cron."
        warn "Adicione manualmente: $rLine"
        return 0
    fi

    if grep -q "epg_patch.php" "$CRONTAB_FILE" 2>/dev/null; then
        ok "Cron do EPG ja configurado."
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] chattr -i $CRONTAB_FILE ; echo \"$rLine\" >> $CRONTAB_FILE ; chattr +i $CRONTAB_FILE"
        return 0
    fi

    chattr -i "$CRONTAB_FILE" 2>/dev/null || true

    if echo "$rLine" >> "$CRONTAB_FILE"; then
        ok "Cron do EPG adicionado (roda a cada minuto)."
    else
        chattr +i "$CRONTAB_FILE" 2>/dev/null || true
        error "Falha ao escrever na crontab."
        return 1
    fi

    chattr +i "$CRONTAB_FILE" 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && systemctl reload cron 2>/dev/null || true
}

##################################################
# STATUS                                         #
##################################################

show_status() {
    echo ""
    echo "=== Estado dos patches ($XUI_ROOT) ==="
    echo ""

    # Cloudflare
    printf "Cloudflare Fix\n"
    if [ -f "$NGINX_CONF" ]; then
        if grep -qE '^[[:space:]]*real_ip_header[[:space:]]+CF-Connecting-IP;' "$NGINX_CONF"; then
            echo -e "  real_ip_header ......... ${C_GREEN}CF-Connecting-IP${C_RESET}"
        else
            echo -e "  real_ip_header ......... ${C_RED}$(grep -oE '^[[:space:]]*real_ip_header[[:space:]]+[^;]*;' "$NGINX_CONF" | head -1 | tr -s ' ' | sed 's/^ //')${C_RESET}"
        fi
    else
        echo -e "  nginx.conf ............. ${C_RED}nao encontrado${C_RESET}"
    fi
    if [ -s "$REALIP_CONF" ]; then
        echo -e "  realip_cloudflare ...... ${C_GREEN}$(grep -c 'set_real_ip_from' "$REALIP_CONF") ranges${C_RESET}"
    else
        echo -e "  realip_cloudflare ...... ${C_RED}vazio${C_RESET}"
    fi
    echo -e "  banco (cf/cdn) ......... $(cf_flags_status)"

    echo ""
    printf "EPG Instant Fix\n"
    if [ -f "$EPG_PATCH" ]; then
        echo -e "  epg_patch.php .......... ${C_GREEN}instalado${C_RESET}"
    else
        echo -e "  epg_patch.php .......... ${C_RED}ausente${C_RESET}"
    fi
    if [ -f "$CRONTAB_FILE" ] && grep -q "epg_patch.php" "$CRONTAB_FILE" 2>/dev/null; then
        echo -e "  cron (root) ............ ${C_GREEN}ativo${C_RESET}"
    else
        echo -e "  cron (root) ............ ${C_RED}ausente${C_RESET}"
    fi
    echo ""
}

##################################################
# MAIN                                           #
##################################################

case "$CMD" in
    status)
        show_status
        ;;
    cloudflare)
        require_xui
        require_root
        echo ""
        if [ "$CONFIRM_ALL" != "1" ] && [ "$DRY_RUN" != "1" ]; then
            warn "Este patch liga o modo Cloudflare/CDN no banco (cloudflare=1, allow_cdn_access=1)."
            warn "Use apenas se o painel realmente estiver atras da Cloudflare."
            ask "Continuar?" "N" || { info "Cancelado."; exit 1; }
        fi
        echo ""
        patch_cloudflare && ok "Cloudflare Fix aplicado." || { error "Cloudflare Fix falhou."; exit 1; }
        echo ""
        ;;
    epg)
        require_xui
        require_root
        echo ""
        patch_epg && ok "EPG Instant Fix aplicado." || { error "EPG Instant Fix falhou."; exit 1; }
        echo ""
        ;;
    all)
        require_xui
        require_root
        echo ""
        if [ "$CONFIRM_ALL" != "1" ] && [ "$DRY_RUN" != "1" ]; then
            warn "O Cloudflare Fix liga o modo Cloudflare/CDN no banco."
            warn "Use apenas se o painel realmente estiver atras da Cloudflare."
            ask "Aplicar tambem o Cloudflare Fix?" "N" || CF_SKIP=1
        fi
        echo ""
        patch_epg || { error "EPG Instant Fix falhou."; exit 1; }
        echo ""
        if [ "${CF_SKIP:-0}" = "1" ]; then
            info "Cloudflare Fix pulado."
        else
            patch_cloudflare || { error "Cloudflare Fix falhou."; exit 1; }
        fi
        echo ""
        ok "Patches aplicados."
        echo ""
        ;;
esac
