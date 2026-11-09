# Google Drive Backup Sync (opcional)

Espelha os backups SQL do XUI.ONE (`/home/xui/backups`) para o Google Drive via
`rclone`, rodando de hora em hora.

> **Este patch é diferente dos outros dois.** Ele **não funciona sozinho**: depois
> de instalado é obrigatório autorizar o Google Drive manualmente com OAuth.
> Até você fazer isso, o cron horário falha silenciosamente.

## Instalação

```bash
sudo ./patchxui.sh gdrive -y
```

Ou manualmente, baixando o instalador original:

```bash
sudo bash patches/gdrive-backup-sync/install.sh
```

O `patchxui.sh` faz o mesmo que o `install.sh` original, mais duas coisas:

- **detecta e usa PHP 8+** (obrigatório, veja abaixo);
- cria um wrapper em `/usr/local/bin/xui-gdrive-sync` já apontando para o PHP correto.

## ⚠️ Requisito: PHP 8.0+

O `sync.php` usa `str_starts_with()`, `match()` e tipos `mixed` — **PHP 8.0+**.

O XUI 1.5.13 embarca apenas **PHP 7.4** em `/home/xui/bin/php/bin/php` (o binário
`php` é literalmente o `php_7.4`, mesmo SHA-256), então **não dá** para reaproveitar
o PHP do painel.

Instale um PHP 8 do sistema:

```bash
# Ubuntu 24.04 já traz 8.3 no repositório padrão
sudo apt-get install -y php-cli

# Ubuntu 20.04/22.04: use o PPA
sudo add-apt-repository -y ppa:ondrej/php
sudo apt-get update
sudo apt-get install -y php8.3-cli
```

O `patchxui.sh` procura por `php8.4`, `php8.3`, `php8.2`, `php8.1`, `php8.0`, `php8`
e `php`, validando `PHP_VERSION_ID >= 80000`. Se não encontrar, aborta com instruções.

## Passo manual obrigatório (OAuth)

```bash
sudo rclone config --config /etc/xui-gdrive-sync/rclone.conf
```

Crie um remote chamado **`gdrive`** do tipo **Google Drive** (`drive`). É um fluxo
interativo: o rclone abre/instrui a abrir uma URL no navegador para você autorizar.
Não há como automatizar isso em script.

## Validar

```bash
sudo xui-gdrive-sync doctor     # checa PHP, paths, rclone e o remote
sudo xui-gdrive-sync status     # resumo local e remoto
sudo xui-gdrive-sync dry-run    # SIMULA — nada é alterado no Drive
sudo xui-gdrive-sync sync       # sincroniza de verdade
sudo tail -n 100 /var/log/xui-gdrive-sync/sync.log
```

**Rode sempre o `dry-run` antes do primeiro `sync`.**

## ⚠️ `rclone sync` é espelho (destrutivo por design)

Não é cópia incremental, é espelho:

- arquivo novo local → sobe para o Drive;
- **arquivo apagado localmente → apagado do Drive** no próximo ciclo.

O script tem proteção contra o pior cenário: se a pasta local não tiver nenhum
arquivo que case com os padrões, ele **aborta** em vez de limpar o Drive
(`allow_empty_source => false` no `config.php`). Não mude isso sem entender.

## Arquivos instalados

| Caminho | O que é |
|---|---|
| `/opt/xui-gdrive-sync/sync.php` | aplicação |
| `/etc/xui-gdrive-sync/config.php` | configuração (preservada em reinstalações) |
| `/etc/xui-gdrive-sync/rclone.conf` | credenciais OAuth (modo 0600) |
| `/usr/local/bin/xui-gdrive-sync` | wrapper com o PHP 8 correto |
| `/etc/cron.d/xui-gdrive-sync` | cron horário (`0 * * * *`) |
| `/etc/logrotate.d/xui-gdrive-sync` | rotação semanal, 8 cópias |
| `/var/log/xui-gdrive-sync/sync.log` | log |

## Desinstalar

```bash
sudo ./patchxui.sh uninstall-gdrive
```

Remove o cron, o logrotate, o wrapper e `/opt/xui-gdrive-sync`. **Preserva de
propósito** `/etc/xui-gdrive-sync` (config + credenciais) e os logs. Para remover tudo:

```bash
sudo rm -rf /etc/xui-gdrive-sync /var/log/xui-gdrive-sync
```

Os backups locais em `/home/xui/backups` **nunca** são tocados.

## Créditos

Código original: [cunninghambr/xui-one-gdrive-backup-sync](https://github.com/cunninghambr/xui-one-gdrive-backup-sync) (MIT).
Os arquivos em `src/`, `config/`, `scripts/`, `install.sh`, `README.md` original e
`LICENSE` são cópias com fim de linha normalizado para LF.
