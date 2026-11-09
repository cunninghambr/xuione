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

Correções aplicadas após a instalação, mantidas neste repositório:

| Patch | Problema que resolve | Pasta |
|---|---|---|
| **Cloudflare Fix** | Login em loop / logout intermitente com o proxy Cloudflare ativo (Nginx vê IP do edge em vez do visitante). | [`patches/cloudflare-fix/`](patches/cloudflare-fix/README.md) — [English](patches/cloudflare-fix/README.md) · [Español](patches/cloudflare-fix/README.es.md) |
| **EPG Instant Fix** | Stream fica até 24 h sem EPG após atribuir um canal, esperando o cron da meia-noite. | [`patches/epg-instant-fix/`](patches/epg-instant-fix/README.md) |

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
