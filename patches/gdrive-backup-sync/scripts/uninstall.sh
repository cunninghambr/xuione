#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="xui-gdrive-sync"
APP_DIR="/opt/${APP_NAME}"
ETC_DIR="/etc/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
BIN_PATH="/usr/local/bin/${APP_NAME}"
CRON_PATH="/etc/cron.d/${APP_NAME}"
LOGROTATE_PATH="/etc/logrotate.d/${APP_NAME}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/uninstall.sh" >&2
  exit 1
fi

rm -f "${CRON_PATH}" "${LOGROTATE_PATH}" "${BIN_PATH}"
rm -rf "${APP_DIR}"
systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1 || true

cat <<EOF
Removed application files and cron entry.

Not removed by default:
  ${ETC_DIR}
  ${LOG_DIR}

To delete configuration, OAuth tokens and logs too, run:
  sudo rm -rf ${ETC_DIR} ${LOG_DIR}
EOF
