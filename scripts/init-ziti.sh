#!/bin/bash
set -e

echo "========================================="
echo "OpenZiti Network Initialization"
echo "========================================="

# Wait for controller to be ready
CONTROLLER_URL="https://${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}"
echo "Waiting for controller to be ready at ${CONTROLLER_URL}..."

MAX_ATTEMPTS=60
ATTEMPT=0
until curl -k -f -s "${CONTROLLER_URL}/version" > /dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
        echo "ERROR: Controller did not become ready in time"
        exit 1
    fi
    echo "  Attempt $ATTEMPT/$MAX_ATTEMPTS - waiting..."
    sleep 5
done

echo "Controller is ready!"
echo ""

# Ensure ziti CLI is on PATH inside container
export PATH="$PATH:/var/openziti/ziti-bin"

# Login to controller
echo "Logging in as admin..."
ziti edge login "${CONTROLLER_URL}" -u "${ZITI_USER}" -p "${ZITI_PWD}" -y

echo ""
echo "========================================="
echo "Configuring Default Policies"
echo "========================================="

# NOTE:
# Router identity/enrollment is handled by run-router.sh in ziti-edge-router container.
# Avoid creating router identity here to prevent race conditions and missing key/cas files.


# Create edge router policy allowing all identities to connect to public routers
echo "Creating edge router policy..."
ziti edge delete edge-router-policy all-endpoints-public-routers 2>/dev/null || true
ziti edge create edge-router-policy all-endpoints-public-routers \
    --edge-router-roles '#public' \
    --identity-roles '#all'

# Create service edge router policy allowing all services to use all routers
echo "Creating service edge router policy..."
ziti edge delete service-edge-router-policy all-services-all-routers 2>/dev/null || true
ziti edge create service-edge-router-policy all-services-all-routers \
    --edge-router-roles '#all' \
    --service-roles '#all'

echo ""

VPN_CIDR="${VPN_CIDR:-10.0.0.0/16}"
VPN_PORT_LOW="${VPN_PORT_LOW:-1}"
VPN_PORT_HIGH="${VPN_PORT_HIGH:-65535}"
VPN_SERVICE_NAME="${VPN_SERVICE_NAME:-vpn-${VPN_CIDR//\//-}}"
VPN_SERVICE_NAME="${VPN_SERVICE_NAME//./-}"

# Minimal validation
if ! [[ "$VPN_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: Invalid VPN_CIDR: $VPN_CIDR"
    exit 1
fi
if ! [[ "$VPN_PORT_LOW" =~ ^[0-9]+$ && "$VPN_PORT_HIGH" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VPN_PORT_LOW/VPN_PORT_HIGH must be numeric"
    exit 1
fi
if (( VPN_PORT_LOW < 1 || VPN_PORT_HIGH > 65535 || VPN_PORT_LOW > VPN_PORT_HIGH )); then
    echo "ERROR: Invalid port range ${VPN_PORT_LOW}-${VPN_PORT_HIGH}"
    exit 1
fi

echo "========================================="
echo "Creating VPN Service for ${VPN_CIDR} (ports ${VPN_PORT_LOW}-${VPN_PORT_HIGH})"
echo "========================================="

# Create intercept config for selected subnet
echo "Creating intercept configuration..."
ziti edge delete config vpn-intercept-config 2>/dev/null || true
ziti edge create config vpn-intercept-config intercept.v1 \
    "{\"protocols\":[\"tcp\",\"udp\"],\"addresses\":[\"${VPN_CIDR}\"],\"portRanges\":[{\"low\":${VPN_PORT_LOW},\"high\":${VPN_PORT_HIGH}}]}"

# Create host config to allow router to reach selected network
echo "Creating host configuration..."
ziti edge delete config vpn-host-config 2>/dev/null || true
ziti edge create config vpn-host-config host.v1 \
    "{\"forwardProtocol\":true,\"allowedProtocols\":[\"tcp\",\"udp\"],\"forwardAddress\":true,\"allowedAddresses\":[\"${VPN_CIDR}\"],\"forwardPort\":true,\"allowedPortRanges\":[{\"low\":${VPN_PORT_LOW},\"high\":${VPN_PORT_HIGH}}]}"

# Create VPN service
echo "Creating VPN service..."
ziti edge delete service "${VPN_SERVICE_NAME}" 2>/dev/null || true
ziti edge create service "${VPN_SERVICE_NAME}" \
    --configs vpn-intercept-config,vpn-host-config \
    -a "vpn-service"

# Create service edge router policy binding
echo "Binding service to edge routers..."
ziti edge delete service-edge-router-policy vpn-service-binding 2>/dev/null || true
ziti edge create service-edge-router-policy vpn-service-binding \
    --service-roles "@${VPN_SERVICE_NAME}" \
    --edge-router-roles '#public'

# Create service policy for dial (client access)
echo "Creating dial service policy..."
ziti edge delete service-policy vpn-dial-policy 2>/dev/null || true
ziti edge create service-policy vpn-dial-policy Dial \
    --service-roles "@${VPN_SERVICE_NAME}" \
    --identity-roles '#vpn-users'

# Create service policy for bind (router hosting)
echo "Creating bind service policy..."
ziti edge delete service-policy vpn-bind-policy 2>/dev/null || true
ziti edge create service-policy vpn-bind-policy Bind \
    --service-roles "@${VPN_SERVICE_NAME}" \
    --identity-roles '#vpn-hosts'

# Tag the edge router as a VPN host (best effort once router exists)
echo "Tagging edge router as VPN host (if router already exists)..."
if ziti edge list edge-routers | grep -q "${ZITI_ROUTER_NAME}"; then
    ziti edge update identity "${ZITI_ROUTER_NAME}" -a "vpn-hosts" || true
else
    echo "  Router not created yet; tag will be applied later."
fi

echo ""
echo "========================================="
echo "Network Initialization Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Configure LDAP sync (ensure LDAP_BIND_PASSWORD is set)"
echo "  2. Create user identities with #vpn-users tag"
echo "  3. Generate enrollment JWTs for clients"
echo ""
echo "Example: Create a test user"
echo "  ziti edge create identity user test-user -a vpn-users -o /persistent/test-user.jwt"
echo ""
