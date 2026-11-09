#!/bin/bash
#
# XUI ONE - Instalador/Atualizador
# https://github.com/cunninghambr/xuione
#
# Uso:
#   ./installxui.sh                  (abre menu interativo)
#   ./installxui.sh install 1.5.13
#   ./installxui.sh update 1.5.12
#
set -e

REPO_URL="https://github.com/cunninghambr/xuione/releases/download/v1.5.13"
VALID_VERSIONS="1.5.5 1.5.12 1.5.13"
XUI_HOME="/home/xui"

C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"

info()  { echo -e "${C_CYAN}[*]${C_RESET} $1"; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $1"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
error() { echo -e "${C_RED}[!]${C_RESET} $1"; }

BANNER_SHOWN=0
banner() {
    [ "$BANNER_SHOWN" -eq 1 ] && return
    BANNER_SHOWN=1
    echo ""
    echo -e "${C_CYAN}===============================================${C_RESET}"
    echo -e "${C_CYAN}   Bem-vindo ao Instalador XUI ONE${C_RESET}"
    echo -e "${C_CYAN}   github.com/cunninghambr/xuione${C_RESET}"
    echo -e "${C_CYAN}===============================================${C_RESET}"
    echo ""
}

usage() {
    echo ""
    echo "Uso: $0 [install|update] [versao]"
    echo "Versoes disponiveis: $VALID_VERSIONS"
    echo ""
    echo "Exemplos:"
    echo "  $0                  (abre menu interativo)"
    echo "  $0 install 1.5.13"
    echo "  $0 update 1.5.12"
    echo ""
    exit 1
}

xui_installed() {
    [ -d "$XUI_HOME" ]
}

select_action() {
    local can_update=1
    xui_installed || can_update=0

    echo "Selecione uma acao:"
    echo "  1) Instalar"
    if [ "$can_update" -eq 1 ]; then
        echo "  2) Atualizar"
    else
        echo "  2) Atualizar (nenhuma instalacao encontrada em $XUI_HOME)"
    fi
    echo ""

    while true; do
        read -rp "Opcao [1-2]: " opt
        case "$opt" in
            1) ACTION="install"; return ;;
            2)
                if [ "$can_update" -eq 1 ]; then
                    ACTION="update"; return
                else
                    warn "Instale o XUI antes de rodar uma atualizacao."
                fi
                ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

select_version() {
    echo ""
    echo "Selecione a versao:"
    echo "  1) 1.5.5"
    echo "  2) 1.5.12"
    echo "  3) 1.5.13"
    echo ""

    while true; do
        read -rp "Opcao [1-3]: " opt
        case "$opt" in
            1) VERSION="1.5.5"; return ;;
            2) VERSION="1.5.12"; return ;;
            3) VERSION="1.5.13"; return ;;
            *) warn "Opcao invalida." ;;
        esac
    done
}

ACTION="$1"
VERSION="$2"

if [ -z "$ACTION" ] && [ -z "$VERSION" ]; then
    banner
    select_action
    select_version
else
    [ -z "$ACTION" ] && usage
    [ -z "$VERSION" ] && usage
fi

case " $VALID_VERSIONS " in
    *" $VERSION "*) ;;
    *) error "Versao invalida: $VERSION"; usage ;;
esac

case "$ACTION" in
    install)
        FILE="XUI_${VERSION}.zip"
        ENTRYPOINT="install"
        ACTION_LABEL="Instalacao"
        ;;
    update)
        FILE="XUI_${VERSION}_UPDATE.zip"
        ENTRYPOINT="update"
        ACTION_LABEL="Atualizacao"
        ;;
    *)
        error "Acao invalida: $ACTION"
        usage
        ;;
esac

if [ "$ACTION" = "update" ] && ! xui_installed; then
    error "Nenhuma instalacao do XUI encontrada em $XUI_HOME. Rode a instalacao antes de atualizar."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    error "Este instalador precisa ser executado como root (use sudo)."
    exit 1
fi

URL="$REPO_URL/$FILE"
WORKDIR="/tmp/xuione-$$"

banner
echo -e "${C_CYAN}   $ACTION_LABEL - versao $VERSION${C_RESET}"
echo ""

if ! command -v unzip >/dev/null 2>&1; then
    info "Instalando dependencia: unzip..."
    apt update -y >/dev/null && apt install -y unzip >/dev/null
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

info "Baixando pacote XUI $VERSION ($ACTION)..."
wget --quiet --show-progress --progress=bar:force:noscroll "$URL" -O "$FILE"

if [ ! -f "$FILE" ]; then
    error "Falha no download. Abortando."
    exit 1
fi

echo ""
info "Extraindo arquivos..."
unzip -oq "$FILE" || { error "Falha na extracao!"; exit 1; }

info "Limpando pacote baixado..."
rm -f "$FILE"

info "Ajustando permissoes..."
chmod +x "$ENTRYPOINT"

ok "Iniciando $ACTION_LABEL do XUI $VERSION..."
echo ""
./"$ENTRYPOINT"
