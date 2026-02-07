#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/openziti-ad-telegram}"
SETUP_BOT="${SETUP_BOT:-true}"      # true/false
SETUP_LDAP_TIMER="${SETUP_LDAP_TIMER:-true}"

log() { printf "[install] %s\n" "$*"; }
err() { printf "[install][error] %s\n" "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Run as root (sudo)."
    exit 1
  fi
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + Compose already present"
    return
  fi

  log "Installing Docker (official convenience script)..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

prepare_project_dir() {
  log "Sync project to ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.env' \
    --exclude 'data' \
    --exclude 'logs' \
    --exclude 'bot/.env' \
    "${PROJECT_DIR}/" "${INSTALL_DIR}/"

  if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
    log "Created ${INSTALL_DIR}/.env from template (edit it before first run)"
  fi

  if [[ ! -f "${INSTALL_DIR}/bot/.env" ]]; then
    cp "${INSTALL_DIR}/bot/.env.example" "${INSTALL_DIR}/bot/.env"
    log "Created ${INSTALL_DIR}/bot/.env from template (edit it before enabling bot)"
  fi

  mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs" "${INSTALL_DIR}/clients" "${INSTALL_DIR}/certs"
  chmod +x "${INSTALL_DIR}/startup.sh" "${INSTALL_DIR}/scripts/"*.sh "${INSTALL_DIR}/install.sh" || true
}

install_bot_service() {
  [[ "${SETUP_BOT}" == "true" ]] || { log "Skipping bot setup"; return; }

  log "Setting up Python venv for Telegram bot"
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip

  python3 -m venv "${INSTALL_DIR}/bot/venv"
  "${INSTALL_DIR}/bot/venv/bin/pip" install -U pip
  "${INSTALL_DIR}/bot/venv/bin/pip" install -r "${INSTALL_DIR}/bot/requirements.txt"

  cat >/etc/systemd/system/ziti-telegram-bot.service <<EOF
[Unit]
Description=OpenZiti Telegram JWT Bot
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/bot/.env
ExecStart=${INSTALL_DIR}/bot/venv/bin/python ${INSTALL_DIR}/bot/telegram_jwt_bot.py
Restart=on-failure
RestartSec=5
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ziti-telegram-bot.service
  log "Bot service enabled"
}

install_ldap_sync_timer() {
  [[ "${SETUP_LDAP_TIMER}" == "true" ]] || { log "Skipping LDAP timer setup"; return; }

  cat >/etc/systemd/system/ziti-ldap-sync.service <<EOF
[Unit]
Description=OpenZiti LDAP sync job
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose exec -T ziti-controller bash /scripts/sync-ldap-users.sh
StandardOutput=append:${INSTALL_DIR}/logs/ldap-sync.log
StandardError=append:${INSTALL_DIR}/logs/ldap-sync.log
EOF

  cat >/etc/systemd/system/ziti-ldap-sync.timer <<'EOF'
[Unit]
Description=Run OpenZiti LDAP sync every 30 minutes

[Timer]
OnBootSec=10m
OnUnitActiveSec=30m
Unit=ziti-ldap-sync.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ziti-ldap-sync.timer
  log "LDAP sync timer enabled"
}

main() {
  require_root
  install_docker_if_missing
  prepare_project_dir

  log "Done. Next steps:"
  log "1) Edit ${INSTALL_DIR}/.env and ${INSTALL_DIR}/bot/.env"
  log "2) Put certificates into ${INSTALL_DIR}/certs"
  log "3) Deploy stack: cd ${INSTALL_DIR} && ./startup.sh"

  install_bot_service
  install_ldap_sync_timer

  log "Installation complete"
}

main "$@"
