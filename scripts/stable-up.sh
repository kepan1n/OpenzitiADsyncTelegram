#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# If custom edge key is mounted from ./certs and selected via env override,
# make it readable for controller process inside container.
if [[ -f certs/cert.key ]]; then
  chmod 644 certs/cert.key 2>/dev/null || true
fi

RUN_INIT="${RUN_INIT:-true}"
REPAIR_MAX_ATTEMPTS="${REPAIR_MAX_ATTEMPTS:-5}"
REPAIR_ENABLED="${REPAIR_ENABLED:-false}"

DOCKER_BIN="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_BIN="sudo docker"
  else
    echo "[stable-up] ERROR: Docker daemon is not accessible (try sudo)." >&2
    exit 1
  fi
fi

d() { ${DOCKER_BIN} "$@"; }
# Bootstrap compose without forced LE edge cert overrides (prevents router enrollment race)
dc_bootstrap() { ZITI_PKI_EDGE_SERVER_CERT= ZITI_PKI_EDGE_KEY= ${DOCKER_BIN} compose "$@"; }
log(){ echo "[stable-up] $*"; }

wait_health() {
  local name="$1" max="${2:-120}" elapsed=0
  while [ "$elapsed" -lt "$max" ]; do
    local st
    st="$(d inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo starting)"
    if [[ "$st" == "healthy" || "$st" == "running" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

router_state() {
  d inspect -f '{{.State.Status}} {{.RestartCount}}' ziti-edge-router 2>/dev/null || echo "missing 0"
}

repair_router_enrollment() {
  log "Attempting router enrollment repair..."
  d compose exec -T ziti-controller bash -lc '
set -e
export PATH=/var/openziti/ziti-bin:$PATH

# Ensure router yaml exists (run-router may leave only .yaml.err)
if [ ! -f /persistent/ziti-edge-router.yaml ] && [ -f /persistent/ziti-edge-router.yaml.err ]; then
  cp /persistent/ziti-edge-router.yaml.err /persistent/ziti-edge-router.yaml
fi

# Login first (writes trusted controller chain under ~/.config/ziti/certs/...)
ziti edge login "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}" -u "${ZITI_USER}" -p "${ZITI_PWD}" -y >/dev/null

# Build trust bundle for router runtime/enroll
issuer="$(echo | openssl s_client -connect "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}" -servername "${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
if echo "$issuer" | grep -qi "Encrypt"; then
  if [ -f /certs/chain.cer ]; then
    cp /certs/chain.cer /persistent/ziti-edge-router.cas
    if [ -f /certs/isrg-root-x1.pem ]; then
      cat /certs/isrg-root-x1.pem >> /persistent/ziti-edge-router.cas
    elif [ -f /etc/ssl/certs/ISRG_Root_X1.pem ]; then
      cat /etc/ssl/certs/ISRG_Root_X1.pem >> /persistent/ziti-edge-router.cas
    fi
  fi
else
  if [ -f "/home/ziti/.config/ziti/certs/${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}" ]; then
    cp "/home/ziti/.config/ziti/certs/${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}" /persistent/ziti-edge-router.cas
  elif [ -f /persistent/pki/cas.pem ]; then
    cp /persistent/pki/cas.pem /persistent/ziti-edge-router.cas
  fi
fi

# Fresh enrollment token
ziti edge create enrollment ott ziti-edge-router -o /persistent/ziti-edge-router.jwt >/dev/null

# Try enroll if yaml exists
if [ -f /persistent/ziti-edge-router.yaml ]; then
  ziti router enroll /persistent/ziti-edge-router.yaml --jwt /persistent/ziti-edge-router.jwt >/dev/null || true
fi

# If cert absent but key exists, keep runtime from crashing by preserving prior cert if any backup exists
if [ ! -f /persistent/ziti-edge-router.cert ] && [ -f /persistent/ziti-edge-router.server.chain.cert ]; then
  cp /persistent/ziti-edge-router.server.chain.cert /persistent/ziti-edge-router.cert
fi
'

  d compose restart ziti-edge-router >/dev/null || true
}

log "Starting controller first..."
dc_bootstrap up -d ziti-controller

# Self-heal rare re-init loop: db exists but access-control.init marker missing
if d logs --tail=80 ziti-controller 2>/dev/null | grep -q "already initialized: Ziti Edge default admin already defined"; then
  PERSIST_VOL="$(d inspect -f '{{range .Mounts}}{{if eq .Destination "/persistent"}}{{.Name}}{{end}}{{end}}' ziti-controller 2>/dev/null || true)"
  if [[ -n "$PERSIST_VOL" ]]; then
    d run --rm -v "${PERSIST_VOL}:/persistent" alpine sh -lc 'touch /persistent/access-control.init' >/dev/null 2>&1 || true
    d restart ziti-controller >/dev/null || true
  fi
fi

log "Waiting for controller health..."
wait_health ziti-controller 180 || { log "Controller not healthy in time"; exit 1; }

log "Starting router + console..."
dc_bootstrap --profile zac up -d ziti-edge-router ziti-console
sleep 5

# Stabilize router (passive wait). Optional active repair can be enabled via REPAIR_ENABLED=true.
attempt=1
while [ "$attempt" -le "$REPAIR_MAX_ATTEMPTS" ]; do
  state_restart="$(router_state)"
  state="${state_restart%% *}"
  restart_count="${state_restart##* }"

  if [[ "$state" == "running" ]]; then
    sleep 4
    state2_restart="$(router_state)"
    state2="${state2_restart%% *}"
    restart2="${state2_restart##* }"
    if [[ "$state2" == "running" && "$restart_count" == "$restart2" ]]; then
      log "Router is stable (restart=$restart2)"
      break
    fi
  fi

  log "Router not stable yet (attempt $attempt/$REPAIR_MAX_ATTEMPTS): $state_restart"
  if [[ "$REPAIR_ENABLED" == "true" ]]; then
    repair_router_enrollment || true
  fi
  sleep 4
  attempt=$((attempt + 1))
done

final_state="$(router_state)"
if [[ "${final_state%% *}" != "running" ]]; then
  log "WARNING: router final state: $final_state"
else
  log "Router final state: $final_state"
fi

if [[ "$RUN_INIT" == "true" ]]; then
  log "Running init job (policies/services)..."
  set +e
  d compose run --rm ziti-controller-init
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "Init returned non-zero ($rc). Continuing."
  fi
fi

# Ensure marker exists to avoid controller re-init loop on recreate
PERSIST_VOL="$(d inspect -f '{{range .Mounts}}{{if eq .Destination "/persistent"}}{{.Name}}{{end}}{{end}}' ziti-controller 2>/dev/null || true)"
if [[ -n "$PERSIST_VOL" ]]; then
  d run --rm -v "${PERSIST_VOL}:/persistent" alpine sh -lc 'touch /persistent/access-control.init' >/dev/null 2>&1 || true
fi

# If custom cert files are present, apply them now (post-bootstrap)
if [[ -f certs/fullchain.cer && -f certs/cert.key && -f certs/chain.cer ]]; then
  log "Applying custom certificates post-bootstrap..."
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo ./scripts/auto-update-certs.sh || log "WARNING: auto-update-certs.sh failed"
  else
    ./scripts/auto-update-certs.sh || log "WARNING: auto-update-certs.sh failed"
  fi
fi

log "Done"
d compose ps
