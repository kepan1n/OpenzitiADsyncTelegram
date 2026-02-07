#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_SCRIPT="$SCRIPT_DIR/auto-update-certs.sh"

echo "=== Setup automatic certificate refresh (cron, every 6h) ==="
chmod +x "$TARGET_SCRIPT"

TMP_CRON="$(mktemp)"
trap 'rm -f "$TMP_CRON"' EXIT

crontab -l 2>/dev/null | grep -v "auto-update-certs.sh" > "$TMP_CRON" || true

cat >> "$TMP_CRON" <<EOF
# OpenZiti certificate auto-refresh
@reboot sleep 60 && cd $PROJECT_DIR && $TARGET_SCRIPT
0 */6 * * * cd $PROJECT_DIR && $TARGET_SCRIPT
EOF

crontab "$TMP_CRON"

echo "Installed cron entries:"
crontab -l | grep "auto-update-certs.sh" || true

echo "Done. Logs: $PROJECT_DIR/logs/cert-renewal.log"
