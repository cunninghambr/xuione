# XUI One

Instruções de instalação e atualização do painel XUI (Ubuntu 20.04–24.04).

## Instalação rápida (recomendado)

Baixe o instalador uma vez e use-o para instalar ou atualizar qualquer versão disponível (`1.5.5`, `1.5.12`, `1.5.13`):

```bash
wget -qO installxui.sh https://raw.githubusercontent.com/cunninghambr/xuione/main/installxui.sh ; chmod +x installxui.sh ; sudo ./installxui.sh
```

Menu interativo:

```bash
sudo ./installxui.sh
```

Executar por parâmetro:

```bash
sudo ./installxui.sh install 1.5.13
sudo ./installxui.sh update 1.5.13
```

O script baixa o pacote certo direto das releases deste repositório, extrai, ajusta as permissões e executa o `install`/`update` automaticamente. Precisa ser executado como root. Tanto o `install` quanto o `update` vão pedir a chave de licença durante a execução.

## Licença

Obtenha sua chave de licença no link [NNetwork](https://portal.nnetwork.net/order/tools/licenca-xuione).
Acesse o portal para gerar/consultar sua licença antes de instalar ou atualizar.

## Patches de melhoria

Correções aplicadas após a instalação, mantidas neste repositório. O instalador
oferece os patches ao final de cada `install`/`update` (perguntando quais aplicar).

Para aplicar (ou reaplicar) a qualquer momento:

```bash
wget -qO patchxui.sh https://raw.githubusercontent.com/cunninghambr/xuione/main/patchxui.sh ; chmod +x patchxui.sh ; sudo ./patchxui.sh all -y
```

Ou por parâmetro:

```bash
sudo ./patchxui.sh status            # mostra o que já está aplicado
sudo ./patchxui.sh epg -y            # EPG na hora
sudo ./patchxui.sh cloudflare -y     # fix de login atrás do Cloudflare
sudo ./patchxui.sh all -y            # os dois (não inclui o gdrive)
DRY_RUN=1 sudo ./patchxui.sh all     # simula, sem alterar nada
```

O script é idempotente (pode rodar quantas vezes quiser), faz backup do
`nginx.conf` antes de alterar e valida a configuração do nginx antes de recarregar.
As faixas de IP da Cloudflare são baixadas ao vivo da API oficial.

> **Atenção:** o Cloudflare Fix liga o modo CDN no banco
> (`cloudflare=1`, `allow_cdn_access=1`). Use apenas se o painel realmente
> estiver atrás do proxy Cloudflare — caso contrário o `root_signals.php`
> esvazia o `realip_cloudflare.conf` e você fica com o modo CDN ligado sem uso.

| Patch | Problema que resolve | Pasta |
|---|---|---|
| **Cloudflare Fix** | Login em loop / logout intermitente com o proxy Cloudflare ativo (Nginx vê IP do edge em vez do visitante). | [`patches/cloudflare-fix/`](patches/cloudflare-fix/README.md) — [English](patches/cloudflare-fix/README.md) · [Español](patches/cloudflare-fix/README.es.md) |
| **EPG Instant Fix** | Stream fica até 24 h sem EPG após atribuir um canal, esperando o cron da meia-noite. | [`patches/epg-instant-fix/`](patches/epg-instant-fix/README.md) |
| **Google Drive Backup Sync** | Backups do painel ficam só no próprio servidor; este espelha para o Google Drive a cada hora. **Requer OAuth manual e PHP 8+.** | [`patches/gdrive-backup-sync/`](patches/gdrive-backup-sync/README.pt-BR.md) |

### Google Drive Backup Sync (opcional, fora do `all`)

Fica fora do `all` de propósito: **não funciona sem um passo manual de OAuth** e
exige PHP 8+ (o PHP embarcado no XUI 1.5.13 é 7.4).

```bash
sudo ./patchxui.sh gdrive -y
sudo rclone config --config /etc/xui-gdrive-sync/rclone.conf   # obrigatório: remote "gdrive"
sudo xui-gdrive-sync dry-run                                   # simule antes
sudo ./patchxui.sh uninstall-gdrive                            # remover
```

Detalhes, requisitos de PHP e o aviso de que `rclone sync` é espelho (apaga no
Drive o que for apagado localmente): [`patches/gdrive-backup-sync/README.pt-BR.md`](patches/gdrive-backup-sync/README.pt-BR.md).

## Dicas para manter o painel estável e com bom desempenho

Parar o painel:

```bash
/home/xui/service stop
```

Iniciar o painel:

```bash
/home/xui/service start
```

Status / atualizar banco de dados:

```bash
/home/xui/status
```

Ferramentas:

```bash
/home/xui/tools
```

Gerar código de resgate:

```bash
/home/xui/tools rescue
```
