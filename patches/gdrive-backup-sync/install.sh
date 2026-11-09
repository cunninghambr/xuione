#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="xui-gdrive-sync"
APP_DIR="/opt/${APP_NAME}"
ETC_DIR="/etc/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
BIN_PATH="/usr/local/bin/${APP_NAME}"
CRON_PATH="/etc/cron.d/${APP_NAME}"
LOGROTATE_PATH="/etc/logrotate.d/${APP_NAME}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR="${SOURCE_DIR:-/home/xui/backups}"
REMOTE_NAME="${REMOTE_NAME:-gdrive}"
REMOTE_DIR="${REMOTE_DIR:-xui-one-backups/{hostname}}"
CRON_MINUTE="${CRON_MINUTE:-0}"
INSTALL_RCLONE="${INSTALL_RCLONE:-1}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo bash install.sh" >&2
    exit 1
  fi
}

validate_input() {
  if ! [[ "${CRON_MINUTE}" =~ ^[0-9]+$ ]] || (( CRON_MINUTE < 0 || CRON_MINUTE > 59 )); then
    echo "CRON_MINUTE must be a number between 0 and 59." >&2
    exit 1
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip php-cli cron
}

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    echo "rclone already installed: $(rclone version | head -n1)"
    return
  fi

  if [[ "${INSTALL_RCLONE}" == "1" ]]; then
    curl https://rclone.org/install.sh | bash
  else
    echo "rclone is not installed and INSTALL_RCLONE=0 was set." >&2
    exit 1
  fi
}

copy_files() {
  mkdir -p "${APP_DIR}" "${ETC_DIR}" "${LOG_DIR}"
  cp "${SRC_DIR}/src/sync.php" "${APP_DIR}/sync.php"
  chmod 0755 "${APP_DIR}/sync.php"

  cat > "${BIN_PATH}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/env php ${APP_DIR}/sync.php "\$@"
EOF
  chmod 0755 "${BIN_PATH}"

  if [[ ! -f "${ETC_DIR}/config.php" ]]; then
    cp "${SRC_DIR}/config/config.example.php" "${ETC_DIR}/config.php"
    sed -i "s#'source_dir' => '/home/xui/backups'#'source_dir' => '${SOURCE_DIR}'#" "${ETC_DIR}/config.php"
    sed -i "s#'remote_name' => 'gdrive'#'remote_name' => '${REMOTE_NAME}'#" "${ETC_DIR}/config.php"
    sed -i "s#'remote_dir' => 'xui-one-backups/{hostname}'#'remote_dir' => '${REMOTE_DIR}'#" "${ETC_DIR}/config.php"
  fi

  touch "${ETC_DIR}/rclone.conf"
  chmod 0600 "${ETC_DIR}/rclone.conf" "${ETC_DIR}/config.php"
  chmod 0750 "${ETC_DIR}" "${LOG_DIR}"
}

install_cron() {
  cat > "${CRON_PATH}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# XUI.ONE backup directory -> Google Drive mirror. Runs hourly.
${CRON_MINUTE} * * * * root ${BIN_PATH} sync >/dev/null 2>&1
EOF
  chmod 0644 "${CRON_PATH}"
  systemctl enable cron >/dev/null 2>&1 || true
  systemctl restart cron || service cron restart || true
}

install_logrotate() {
  cat > "${LOGROTATE_PATH}" <<EOF
${LOG_DIR}/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
  chmod 0644 "${LOGROTATE_PATH}"
}

print_next_steps() {
  cat <<EOF

Installed ${APP_NAME}.

Next steps:
1) Configure the Google Drive remote:
   sudo rclone config --config ${ETC_DIR}/rclone.conf

   Create a remote named: ${REMOTE_NAME}
   Storage type: Google Drive / drive

2) Validate the installation:
   sudo ${BIN_PATH} doctor

3) Test without changing Google Drive:
   sudo ${BIN_PATH} dry-run

4) Run the real sync:
   sudo ${BIN_PATH} sync

5) Check status/logs:
   sudo ${BIN_PATH} status
   sudo tail -n 100 ${LOG_DIR}/sync.log

Cron file:
   ${CRON_PATH}

Config file:
   ${ETC_DIR}/config.php
EOF
}

require_root
validate_input
install_packages
install_rclone
copy_files
install_cron
install_logrotate
print_next_steps
