#!/usr/bin/env bash
set -euo pipefail

# Apply/refresh custom TLS certificates for OpenZiti from ./certs
# Expected files:
#   certs/fullchain.cer
#   certs/cert.key
#   certs/chain.cer
#
# Also builds CA bundles:
#   certs/fullchain-ca.cer = chain.cer + ISRG Root X1
#   certs/combined-ca.cer  = ziti-edge-router.cas + fullchain-ca.cer (if router CA exists)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_DIR/logs/cert-renewal.log"

mkdir -p "$PROJECT_DIR/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cd "$PROJECT_DIR"

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

CERT_FILE="certs/fullchain.cer"
KEY_FILE="certs/cert.key"
CHAIN_FILE="certs/chain.cer"
LE_ROOT_FILE="certs/isrg-root-x1.pem"
FULLCHAIN_CA_FILE="certs/fullchain-ca.cer"
COMBINED_CA_FILE="certs/combined-ca.cer"
STAMP_FILE="certs/.last-applied.sha256"

for f in "$CERT_FILE" "$KEY_FILE" "$CHAIN_FILE"; do
  if [ ! -f "$f" ]; then
    log "ERROR: missing required file: $f"
    exit 1
  fi
done

# Basic sanity checks
if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
  log "ERROR: invalid X509 certificate: $CERT_FILE"
  exit 1
fi
if ! openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1; then
  log "ERROR: invalid private key: $KEY_FILE"
  exit 1
fi

cert_pub="$(openssl x509 -in "$CERT_FILE" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
key_pub="$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
if [ -z "$cert_pub" ] || [ -z "$key_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
  log "ERROR: certificate and private key do not match"
  exit 1
fi

if [ ! -f "$LE_ROOT_FILE" ]; then
  log "Downloading ISRG Root X1"
  curl -fsSL https://letsencrypt.org/certs/isrgrootx1.pem -o "$LE_ROOT_FILE"
fi

cat "$CHAIN_FILE" "$LE_ROOT_FILE" > "$FULLCHAIN_CA_FILE"
log "Built $FULLCHAIN_CA_FILE"

fingerprint="$(sha256sum "$CERT_FILE" "$KEY_FILE" "$CHAIN_FILE" "$FULLCHAIN_CA_FILE" | sha256sum | awk '{print $1}')"
if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$fingerprint" ]; then
  log "No certificate changes detected"
  exit 0
fi

if ! docker compose ps >/dev/null 2>&1; then
  log "ERROR: docker compose is not available or stack is not initialized"
  exit 1
fi

# Best effort: if router CA exists, build combined CA bundle
if docker compose exec -T ziti-controller sh -lc 'test -f /persistent/ziti-edge-router.cas' >/dev/null 2>&1; then
  docker compose exec -T ziti-controller sh -lc 'cat /persistent/ziti-edge-router.cas' > certs/.ziti-router.cas.tmp
  cat certs/.ziti-router.cas.tmp "$FULLCHAIN_CA_FILE" > "$COMBINED_CA_FILE"
  rm -f certs/.ziti-router.cas.tmp
  log "Built $COMBINED_CA_FILE (router CA + LE chain)"
else
  cp "$FULLCHAIN_CA_FILE" "$COMBINED_CA_FILE"
  log "Built $COMBINED_CA_FILE (LE chain only; router CA not found yet)"
fi

log "Applying certificates to /persistent/pki/custom via cert-setup.sh (as root)"
docker compose exec -T -u root ziti-controller bash /scripts/cert-setup.sh >/dev/null

log "Restarting controller"
docker compose restart ziti-controller >/dev/null

log "Waiting for controller health"
max_wait=120
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
  if docker compose ps ziti-controller | grep -Eq "healthy|running|Up"; then
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done

if [ "$elapsed" -ge "$max_wait" ]; then
  log "WARNING: controller did not report healthy state in ${max_wait}s"
fi

# Reconcile router trust to avoid restart loops after cert rotation
log "Reconciling router trust bundle and restarting router"
docker compose exec -T ziti-controller sh -lc '
set -e
if [ -f /persistent/pki/cas.pem ] && [ -f /certs/fullchain-ca.cer ]; then
  cat /persistent/pki/cas.pem /certs/fullchain-ca.cer > /persistent/combined-ca.cer
elif [ -f /certs/fullchain-ca.cer ]; then
  cp /certs/fullchain-ca.cer /persistent/combined-ca.cer
fi

if [ -f /persistent/ziti-edge-router.yaml.err ] && [ ! -f /persistent/ziti-edge-router.yaml ]; then
  cp /persistent/ziti-edge-router.yaml.err /persistent/ziti-edge-router.yaml
fi

if [ -f /persistent/ziti-edge-router.yaml ] && [ -f /persistent/combined-ca.cer ]; then
  sed -i "s|ca:.*\"/persistent/ziti-edge-router.cas\"|ca:               \"/persistent/combined-ca.cer\"|" /persistent/ziti-edge-router.yaml || true
  if ! sed -n "/^ctrl:/,/^link:/p" /persistent/ziti-edge-router.yaml | grep -q "ca: /persistent/combined-ca.cer"; then
    sed -i "/^ctrl:/a\  options:\n    ca: /persistent/combined-ca.cer" /persistent/ziti-edge-router.yaml || true
  fi
fi
'

docker compose restart ziti-edge-router >/dev/null || true
sleep 6

router_status="$(docker compose ps ziti-edge-router || true)"
if echo "$router_status" | grep -Eq "Restarting|Exited"; then
  log "WARNING: router still unstable after cert reconcile"
else
  log "Router restart completed"
fi

echo "$fingerprint" > "$STAMP_FILE"
log "Certificate update completed"
