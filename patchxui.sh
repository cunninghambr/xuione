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

# Google Drive Backup Sync (patch opcional)
GDRIVE_APP_DIR="${GDRIVE_APP_DIR:-/opt/xui-gdrive-sync}"
GDRIVE_ETC_DIR="${GDRIVE_ETC_DIR:-/etc/xui-gdrive-sync}"
GDRIVE_BIN="${GDRIVE_BIN:-/usr/local/bin/xui-gdrive-sync}"
GDRIVE_BACKUP_SRC="${GDRIVE_BACKUP_SRC:-$XUI_ROOT/backups}"
GDRIVE_CRON_FILE="${GDRIVE_CRON_FILE:-/etc/cron.d/xui-gdrive-sync}"
GDRIVE_LOGROTATE_FILE="${GDRIVE_LOGROTATE_FILE:-/etc/logrotate.d/xui-gdrive-sync}"
GDRIVE_LOG_DIR="${GDRIVE_LOG_DIR:-/var/log/xui-gdrive-sync}"

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
    echo "Uso: $0 [status|epg|cloudflare|all|gdrive|uninstall-gdrive] [-y] [-f]"
    echo ""
    echo "  status            mostra o estado atual dos patches"
    echo "  epg               aplica o EPG Instant Fix"
    echo "  cloudflare        aplica o Cloudflare Fix"
    echo "  all               aplica os dois (NAO inclui o gdrive)"
    echo "  gdrive            instala o Google Drive Backup Sync (requer OAuth depois)"
    echo "  uninstall-gdrive  remove o Google Drive Backup Sync"
    echo "  -y, --yes         nao pedir confirmacao"
    echo "  -f, --force       reescrever mesmo se ja configurado"
    echo ""
    echo "Variaveis de ambiente: XUI_ROOT, DRY_RUN=1, MYSQL_CMD, CRONTAB_FILE"
    echo ""
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        status|epg|cloudflare|all|gdrive|uninstall-gdrive) CMD="$arg" ;;
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
# GOOGLE DRIVE BACKUP SYNC (opcional)            #
##################################################

# O sync.php usa str_starts_with(), match() e mixed (tipos) -> exige PHP 8.0+.
# O XUI 1.5.13 embarca apenas PHP 7.4 (bin/php/bin/php), entao nao podemos usar
# o PHP do painel: precisamos de um php8 no sistema.
find_php8() {
    local rCand
    for rCand in php8.4 php8.3 php8.2 php8.1 php8.0 php8 php; do
        if command -v "$rCand" >/dev/null 2>&1; then
            local rVer
            rVer=$("$rCand" -r 'echo PHP_VERSION_ID;' 2>/dev/null)
            if [ -n "$rVer" ] && [ "$rVer" -ge 80000 ] 2>/dev/null; then
                echo "$rCand"
                return 0
            fi
        fi
    done
    return 1
}

gdrive_php_ver() {
    find_php8 >/dev/null 2>&1 && { "$(find_php8)" -r 'echo PHP_VERSION;' 2>/dev/null; } || echo "ausente"
}

gdrive_status() {
    if [ ! -f "$GDRIVE_APP_DIR/sync.php" ]; then
        echo "nao instalado"
        return
    fi
    local rPhp rRemotes
    rPhp=$(gdrive_php_ver)
    if [ "$rPhp" = "ausente" ]; then
        echo "instalado, mas SEM PHP 8 (sync inoperante)"
        return
    fi
    rRemotes=$(rclone --config "$GDRIVE_ETC_DIR/rclone.conf" listremotes 2>/dev/null | tr -d ':' | tr '\n' ' ')
    if [ -z "$rRemotes" ]; then
        echo "instalado, aguardando rclone config (OAuth pendente)"
    else
        echo "operacional (remotes: $rRemotes)"
    fi
}

patch_gdrive() {
    info "Google Drive Backup Sync"
    warn "Este patch NAO funciona sozinho: depois de instalar e obrigatorio"
    warn "autorizar o Google Drive com: sudo rclone config --config $GDRIVE_ETC_DIR/rclone.conf"
    warn "Ate la, o cron horario falha silenciosamente."
    echo ""

    # 1) PHP 8+ (o PHP do XUI e 7.4)
    info "1/5 Verificando PHP 8+ ..."
    local rPhpBin
    if ! rPhpBin=$(find_php8); then
        error "Nenhum PHP 8.0+ encontrado no sistema."
        error "O sync.php usa str_starts_with()/match(), que nao existem no PHP 7.4 do XUI."
        error "Instale primeiro:  sudo apt-get install -y php-cli"
        error "Se o apt trouxer PHP 7.4, use o PPA:  sudo add-apt-repository -y ppa:ondrej/php && sudo apt-get install -y php8.3-cli"
        return 1
    fi
    ok "PHP 8+ encontrado: $rPhpBin ($("$rPhpBin" -r 'echo PHP_VERSION;' 2>/dev/null))"

    # 2) rclone
    info "2/5 Verificando rclone ..."
    if command -v rclone >/dev/null 2>&1; then
        ok "rclone ja instalado ($(rclone version 2>/dev/null | head -1))"
    else
        if [ "$DRY_RUN" = "1" ]; then
            echo "    [dry-run] curl https://rclone.org/install.sh | bash"
        else
            info "Instalando rclone (script oficial)..."
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 \
                    && ok "rclone instalado" \
                    || { error "Falha ao instalar o rclone."; return 1; }
            else
                error "curl ausente; instale o rclone manualmente e rode de novo."
                return 1
            fi
        fi
    fi

    # 3) Arquivos da aplicacao
    info "3/5 Copiando arquivos para $GDRIVE_APP_DIR e $GDRIVE_ETC_DIR ..."
    local rSrcSync="" rSrcCfg=""
    for rCand in "$SELF_DIR/patches/gdrive-backup-sync" "$SELF_DIR/gdrive-backup-sync"; do
        [ -f "$rCand/src/sync.php" ] && rSrcSync="$rCand/src/sync.php" && rSrcCfg="$rCand/config/config.example.php" && break
    done

    if [ -z "$rSrcSync" ]; then
        info "Baixando sync.php e config do repositorio..."
        local rTmpFetch="$SELF_DIR/.gdrive-fetch.$$"
        mkdir -p "$rTmpFetch" 2>/dev/null
        if command -v wget >/dev/null 2>&1; then
            wget -qO "$rTmpFetch/sync.php" "$RAW_BASE/patches/gdrive-backup-sync/src/sync.php" \
              && wget -qO "$rTmpFetch/config.example.php" "$RAW_BASE/patches/gdrive-backup-sync/config/config.example.php" \
              || { error "Falha no download dos arquivos."; rm -rf "$rTmpFetch"; return 1; }
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL -o "$rTmpFetch/sync.php" "$RAW_BASE/patches/gdrive-backup-sync/src/sync.php" \
              && curl -fsSL -o "$rTmpFetch/config.example.php" "$RAW_BASE/patches/gdrive-backup-sync/config/config.example.php" \
              || { error "Falha no download dos arquivos."; rm -rf "$rTmpFetch"; return 1; }
        else
            error "Sem wget/curl e sem copia local dos arquivos."
            return 1
        fi
        rSrcSync="$rTmpFetch/sync.php"
        rSrcCfg="$rTmpFetch/config.example.php"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] mkdir -p $GDRIVE_APP_DIR $GDRIVE_ETC_DIR $GDRIVE_LOG_DIR"
    else
        if ! mkdir -p "$GDRIVE_APP_DIR" "$GDRIVE_ETC_DIR" "$GDRIVE_LOG_DIR" 2>/dev/null; then
            error "Falha ao criar os diretorios da aplicacao."
            return 1
        fi
        run cp -f "$rSrcSync" "$GDRIVE_APP_DIR/sync.php" || { error "Falha ao copiar sync.php"; return 1; }
        run chmod 0755 "$GDRIVE_APP_DIR/sync.php" 2>/dev/null
    fi

    # config.php so e criado se ainda nao existir (preserva ajustes do cliente)
    if [ -f "$GDRIVE_ETC_DIR/config.php" ]; then
        ok "config.php existente preservado."
    else
        run cp -f "$rSrcCfg" "$GDRIVE_ETC_DIR/config.php"
        run sed -i "s#'source_dir' => '/home/xui/backups'#'source_dir' => '$GDRIVE_BACKUP_SRC'#" "$GDRIVE_ETC_DIR/config.php"
        ok "config.php criado (source_dir=$GDRIVE_BACKUP_SRC)."
    fi

    # wrapper que forca o PHP 8 correto
    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] escreveria $GDRIVE_BIN usando $rPhpBin"
        ok "Wrapper seria criado: $GDRIVE_BIN"
    else
        run mkdir -p "$(dirname "$GDRIVE_BIN")" 2>/dev/null || true
        if cat > "$GDRIVE_BIN" 2>/dev/null <<EOF
#!/usr/bin/env bash
exec $rPhpBin $GDRIVE_APP_DIR/sync.php "\$@"
EOF
        then
            chmod 0755 "$GDRIVE_BIN" 2>/dev/null
            ok "Wrapper criado: $GDRIVE_BIN"
        else
            error "Falha ao criar o wrapper $GDRIVE_BIN"
            return 1
        fi
    fi

    run touch "$GDRIVE_ETC_DIR/rclone.conf"
    run chmod 0600 "$GDRIVE_ETC_DIR/rclone.conf" "$GDRIVE_ETC_DIR/config.php"
    run chmod 0750 "$GDRIVE_ETC_DIR" "$GDRIVE_LOG_DIR"

    [ -n "${rTmpFetch:-}" ] && run rm -rf "$rTmpFetch"

    # 4) Cron horario em /etc/cron.d (nao mexe na crontab travada do root)
    info "4/5 Configurando cron horario em $GDRIVE_CRON_FILE ..."
    local rCronFile="$GDRIVE_CRON_FILE"
    if [ "$DRY_RUN" = "1" ]; then
        echo "    [dry-run] escreveria $rCronFile"
        ok "Cron seria criado: $rCronFile"
    else
        if cat > "$rCronFile" 2>/dev/null <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# XUI.ONE /home/xui/backups -> Google Drive (mirror horario)
0 * * * * root $GDRIVE_BIN sync >/dev/null 2>&1
EOF
        then
            chmod 0644 "$rCronFile" 2>/dev/null
            ok "Cron criado: $rCronFile"
        else
            error "Falha ao criar $rCronFile (o sync NAO vai rodar sozinho)."
            warn "Crie manualmente a linha em /etc/cron.d/:"
            echo "    0 * * * * root $GDRIVE_BIN sync >/dev/null 2>&1"
            return 1
        fi
    fi

    # logrotate (melhor esforco: nao aborta a instalacao)
    if [ "$DRY_RUN" != "1" ]; then
        if cat > "$GDRIVE_LOGROTATE_FILE" 2>/dev/null <<EOF
$GDRIVE_LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
        then
            chmod 0644 "$GDRIVE_LOGROTATE_FILE" 2>/dev/null
        else
            warn "Nao foi possivel criar o logrotate (o sync funciona sem ele)."
        fi
    fi

    # 5) Doctor (sem exigir OAuth ainda)
    if [ "$DRY_RUN" != "1" ] && [ -x "$GDRIVE_BIN" ]; then
        info "5/5 Validando instalacao (doctor)..."
        "$GDRIVE_BIN" doctor 2>&1 | sed 's/^/    /' || true
    fi

    echo ""
    warn "=== FALTA UM PASSO MANUAL (obrigatorio) ==="
    echo "    sudo rclone config --config $GDRIVE_ETC_DIR/rclone.conf"
    echo "    -> crie um remote chamado 'gdrive' do tipo Google Drive"
    echo ""
    echo "  Depois valide:"
    echo "    sudo $GDRIVE_BIN status     # ve arquivos locais e remotos"
    echo "    sudo $GDRIVE_BIN dry-run    # simula, sem alterar o Drive"
    echo "    sudo $GDRIVE_BIN sync       # sincroniza de verdade"
    echo ""
    warn "ATENCAO: e 'rclone sync' (espelho). Arquivo apagado em $GDRIVE_BACKUP_SRC"
    warn "tambem sera apagado do Google Drive no proximo ciclo."
    echo ""
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
    printf "Google Drive Backup Sync (opcional)\n"
    local rGdSt rGdCron="$GDRIVE_CRON_FILE"
    rGdSt=$(gdrive_status)
    case "$rGdSt" in
        operacional*) echo -e "  estado ................. ${C_GREEN}$rGdSt${C_RESET}" ;;
        "nao instalado") echo -e "  estado ................. ${C_RED}$rGdSt${C_RESET}" ;;
        *) echo -e "  estado ................. ${C_YELLOW}$rGdSt${C_RESET}" ;;
    esac
    echo -e "  php 8 (necessario) ..... $(gdrive_php_ver)"
    if [ -f "$rGdCron" ]; then
        echo -e "  cron (horario) ......... ${C_GREEN}ativo${C_RESET}"
    else
        echo -e "  cron (horario) ......... ${C_RED}ausente${C_RESET}"
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
    gdrive)
        require_root
        echo ""
        if [ "$CONFIRM_ALL" != "1" ] && [ "$DRY_RUN" != "1" ]; then
            warn "O Google Drive Backup Sync exige OAuth manual no fim da instalacao."
            warn "Ele tambem precisa de PHP 8+ (o PHP do XUI e 7.4)."
            ask "Continuar?" "N" || { info "Cancelado."; exit 1; }
        fi
        echo ""
        patch_gdrive && ok "Google Drive Backup Sync instalado (OAuth pendente)." \
            || { error "Google Drive Backup Sync falhou."; exit 1; }
        echo ""
        ;;
    uninstall-gdrive)
        require_root
        echo ""
        info "Removendo Google Drive Backup Sync (backups locais NAO sao tocados)..."
        rm -f "$GDRIVE_CRON_FILE" "$GDRIVE_LOGROTATE_FILE" "$GDRIVE_BIN" 2>/dev/null
        rm -rf "$GDRIVE_APP_DIR" 2>/dev/null
        ok "Cron, wrapper e $GDRIVE_APP_DIR removidos."
        warn "Config e credenciais preservados de proposito em $GDRIVE_ETC_DIR"
        warn "Remova manualmente se quiser: sudo rm -rf $GDRIVE_ETC_DIR $GDRIVE_LOG_DIR"
        echo ""
        ;;
esac
