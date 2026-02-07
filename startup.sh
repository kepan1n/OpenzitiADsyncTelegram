#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  OpenZiti Docker Deployment${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ] && ! groups | grep -q docker; then
    echo -e "${YELLOW}WARNING: Not running as root or in docker group. You may encounter permission issues.${NC}"
fi

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}ERROR: .env file not found${NC}"
    echo "Please create .env file with required configuration"
    exit 1
fi

echo -e "${GREEN}✓${NC} Loading environment variables from .env"
set -a
source .env
set +a

echo ""
echo -e "${BLUE}Pre-flight Checks${NC}"
echo "-----------------------------------"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker not found${NC}"
    echo "Please install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi
echo -e "${GREEN}✓${NC} Docker installed: $(docker --version | cut -d' ' -f3 | cut -d',' -f1)"

# Check Docker Compose
if ! docker compose version &> /dev/null; then
    echo -e "${RED}✗ Docker Compose not found${NC}"
    echo "Please install Docker Compose V2"
    exit 1
fi
echo -e "${GREEN}✓${NC} Docker Compose installed: $(docker compose version --short)"

# AppArmor sanity check (common cause of: "docker-default profile could not be loaded")
# If /etc/apparmor.d contains NUL bytes, apparmor_parser fails and Docker cannot start containers.
if command -v aa-status &> /dev/null || [ -d /etc/apparmor.d ]; then
    if [ -r /etc/apparmor.d/tunables/home.d/ubuntu ]; then
        if LC_ALL=C grep -q $'\x00' /etc/apparmor.d/tunables/home.d/ubuntu 2>/dev/null; then
            echo -e "${RED}✗ AppArmor profile file contains NUL bytes:${NC} /etc/apparmor.d/tunables/home.d/ubuntu"
            echo "  Fix (make a backup first):"
            echo "    sudo cp -a /etc/apparmor.d/tunables/home.d/ubuntu /etc/apparmor.d/tunables/home.d/ubuntu.bak.$(date +%F_%H%M%S)"
            echo "    sudo perl -i -pe 's/\\x00//g' /etc/apparmor.d/tunables/home.d/ubuntu"
            echo "    sudo systemctl restart apparmor"
            echo "    sudo systemctl restart docker"
            exit 1
        fi
    fi
fi

# Check certificate files
echo -e "${GREEN}✓${NC} Checking certificate files..."
CERT_ERRORS=0

if [ ! -f "certs/fullchain.cer" ]; then
    echo -e "${RED}  ✗ Missing: certs/fullchain.cer${NC}"
    CERT_ERRORS=$((CERT_ERRORS + 1))
else
    echo -e "${GREEN}  ✓${NC} Found: certs/fullchain.cer"
fi

if [ ! -f "certs/cert.key" ]; then
    echo -e "${RED}  ✗ Missing: certs/cert.key${NC}"
    CERT_ERRORS=$((CERT_ERRORS + 1))
else
    echo -e "${GREEN}  ✓${NC} Found: certs/cert.key"
fi

if [ ! -f "certs/chain.cer" ]; then
    echo -e "${RED}  ✗ Missing: certs/chain.cer${NC}"
    CERT_ERRORS=$((CERT_ERRORS + 1))
else
    echo -e "${GREEN}  ✓${NC} Found: certs/chain.cer"
fi

if [ $CERT_ERRORS -gt 0 ]; then
    echo -e "${RED}ERROR: Missing required certificate files${NC}"
    exit 1
fi

# Check LDAP password
if [ -z "${LDAP_BIND_PASSWORD}" ]; then
    echo -e "${YELLOW}⚠ WARNING: LDAP_BIND_PASSWORD not set in .env${NC}"
    echo "  LDAP synchronization will not work until password is added"
    echo "  Add the following line to .env:"
    echo "  LDAP_BIND_PASSWORD=your_password_here"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✓${NC} LDAP_BIND_PASSWORD is set"
fi

# Check required environment variables
echo -e "${GREEN}✓${NC} Checking configuration..."
REQUIRED_VARS=(
    "ZITI_CTRL_EDGE_ADVERTISED_ADDRESS"
    "ZITI_CTRL_EDGE_ADVERTISED_PORT"
    "ZITI_CTRL_ADVERTISED_ADDRESS"
    "ZITI_CTRL_ADVERTISED_PORT"
    "ZITI_ROUTER_ADVERTISED_ADDRESS"
    "ZITI_ROUTER_PORT"
    "ZITI_USER"
    "ZITI_PWD"
)

CONFIG_ERRORS=0
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo -e "${RED}  ✗ Missing: ${VAR}${NC}"
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
    fi
done

if [ $CONFIG_ERRORS -gt 0 ]; then
    echo -e "${RED}ERROR: Missing required configuration variables${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Configuration validated"

echo ""
echo -e "${BLUE}Deployment Configuration${NC}"
echo "-----------------------------------"
echo "  Controller: ${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}"
echo "  Router: ${ZITI_ROUTER_ADVERTISED_ADDRESS}:${ZITI_ROUTER_PORT}"
echo "  NAT IP: ${ZITI_CTRL_EDGE_IP_OVERRIDE}"
echo "  Admin User: ${ZITI_USER}"
echo "  Admin Password: ********"
echo ""

# Create necessary directories
echo -e "${BLUE}Creating directories...${NC}"
mkdir -p data/controller data/router logs

# Check if this is first-time setup
FIRST_TIME=false
if [ ! -f "data/controller/.initialized" ]; then
    FIRST_TIME=true
fi

echo ""
echo -e "${BLUE}Starting Docker Compose...${NC}"
echo "-----------------------------------"

# Start services
docker compose --profile zac up -d

# Wait for services to be healthy
echo ""
echo "Waiting for services to start..."
sleep 5

# Check container status
echo ""
docker compose ps

# Wait for controller to be healthy
echo ""
echo "Waiting for controller to be ready..."
MAX_WAIT=120
WAIT_TIME=0
CONTROLLER_URL="https://${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}"

while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    if curl -k -f -s "${CONTROLLER_URL}/version" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Controller is ready!"
        break
    fi
    echo -n "."
    sleep 3
    WAIT_TIME=$((WAIT_TIME + 3))
done
echo ""

if [ $WAIT_TIME -ge $MAX_WAIT ]; then
    echo -e "${RED}ERROR: Controller did not become ready in time${NC}"
    echo "Check logs: docker compose logs ziti-controller"
    exit 1
fi

# Run initialization if first time
if [ "$FIRST_TIME" = true ]; then
    echo ""
    echo -e "${BLUE}Running first-time initialization...${NC}"
    echo "-----------------------------------"
    
    # Run initialization script inside controller container
    docker compose exec -T ziti-controller bash /scripts/init-ziti.sh
    
    # Mark as initialized
    touch data/controller/.initialized
    
    echo ""
    echo -e "${GREEN}✓${NC} Initialization complete!"
fi

echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "${YELLOW}Access Information:${NC}"
echo "-----------------------------------"
echo "  Controller Web UI: ${CONTROLLER_URL}"
echo "  Admin Username: ${ZITI_USER}"
echo "  Admin Password: ********"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "-----------------------------------"
echo "  View logs:"
echo "    docker compose logs -f"
echo ""
echo "  Access controller:"
echo "    docker compose exec ziti-controller bash"
echo ""
echo "  Run LDAP sync:"
echo "    docker compose exec ziti-controller bash /scripts/sync-ldap-users.sh"
echo ""
echo "  Create user enrollment:"
echo "    docker compose exec ziti-controller ziti edge create identity user USERNAME -a vpn-users -o /persistent/USERNAME.jwt"
echo ""
echo "  Stop services:"
echo "    docker compose down"
echo ""
echo "  View network status:"
echo "    docker compose exec ziti-controller ziti edge list edge-routers"
echo "    docker compose exec ziti-controller ziti edge list services"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "-----------------------------------"
if [ -n "${LDAP_BIND_PASSWORD}" ]; then
    echo "  1. Run LDAP sync to import users from AD"
    echo "     docker compose exec ziti-controller bash /scripts/sync-ldap-users.sh"
    echo ""
    echo "  2. Download enrollment JWTs from: data/controller/enrollments/"
else
    echo "  1. Add LDAP_BIND_PASSWORD to .env file"
    echo "  2. Restart services: docker compose restart"
    echo "  3. Run LDAP sync to import users"
fi
echo "  3. Install Ziti Desktop Edge on client devices"
echo "  4. Enroll clients using JWT tokens"
echo "  5. Test VPN access to 10.0.0.0/16 network"
echo ""
