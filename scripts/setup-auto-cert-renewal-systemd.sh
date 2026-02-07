#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="openziti-cert-refresh.service"
TIMER_NAME="openziti-cert-refresh.timer"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

cat >/etc/systemd/system/${SERVICE_NAME} <<EOF
[Unit]
Description=OpenZiti certificate refresh job
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/env bash ${PROJECT_DIR}/scripts/auto-update-certs.sh
EOF

cat >/etc/systemd/system/${TIMER_NAME} <<EOF
[Unit]
Description=Run OpenZiti certificate refresh every 6 hours

[Timer]
OnBootSec=2m
OnUnitActiveSec=6h
Unit=${SERVICE_NAME}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ${TIMER_NAME}

echo "Installed and started ${TIMER_NAME}"
systemctl status --no-pager ${TIMER_NAME} | sed -n '1,12p'
echo "Manual run: sudo systemctl start ${SERVICE_NAME}"
