#!/usr/bin/env bash
set -euo pipefail

echo "[deprecated] Use scripts/auto-update-certs.sh instead."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/auto-update-certs.sh"