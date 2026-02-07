#!/bin/bash
set -e

# Set PATH to include ziti binaries
export PATH=/var/openziti/ziti-bin:$PATH

echo "========================================="
echo "OpenZiti LDAP User Synchronization"
echo "Started: $(date)"
echo "========================================="

# Check required variables
if [ -z "${LDAP_SERVER}" ]; then
    echo "ERROR: LDAP_SERVER not set"
    exit 1
fi

if [ -z "${LDAP_BIND_DN}" ]; then
    echo "ERROR: LDAP_BIND_DN not set"
    exit 1
fi

if [ -z "${LDAP_BIND_PASSWORD}" ]; then
    echo "ERROR: LDAP_BIND_PASSWORD not set. Please add it to .env file"
    exit 1
fi

if [ -z "${LDAP_GROUP_DN}" ]; then
    echo "ERROR: LDAP_GROUP_DN not set"
    exit 1
fi

if [ -z "${LDAP_BASE_DN}" ]; then
    echo "ERROR: LDAP_BASE_DN not set"
    exit 1
fi

# Install ldapsearch if not present
if ! command -v ldapsearch &> /dev/null; then
    echo "Installing ldap-utils..."
    apt-get update -qq && apt-get install -y -qq ldap-utils > /dev/null 2>&1
fi

# Login to Ziti controller
CONTROLLER_URL="https://${ZITI_CTRL_EDGE_ADVERTISED_ADDRESS}:${ZITI_CTRL_EDGE_ADVERTISED_PORT}"
echo "Logging into Ziti controller..."
ziti edge login "${CONTROLLER_URL}" -u "${ZITI_USER}" -p "${ZITI_PWD}" -y > /dev/null 2>&1

# Query LDAP for VPN group members
echo "Querying LDAP for VPN group members..."
echo "  LDAP Server: ${LDAP_SERVER}"
echo "  Group DN: ${LDAP_GROUP_DN}"

# Extract members from the VPN group (handle both regular and base64-encoded)
# Use -o ldif-wrap=no to prevent line wrapping
MEMBERS=$(ldapsearch -x -LLL -o ldif-wrap=no -H "${LDAP_SERVER}" \
    -D "${LDAP_BIND_DN}" \
    -w "${LDAP_BIND_PASSWORD}" \
    -b "${LDAP_GROUP_DN}" \
    -s base \
    "(objectClass=*)" member 2>/dev/null | \
    awk '
        /^member::/ {
            # Base64 encoded - decode it
            cmd = "echo " $2 " | base64 -d"
            cmd | getline decoded
            close(cmd)
            print decoded
            next
        }
        /^member:/ {
            # Regular member - print everything after "member: "
            sub(/^member: /, "")
            print
        }
    ')

if [ -z "$MEMBERS" ]; then
    echo "WARNING: No members found in VPN group"
    exit 0
fi

echo "Found $(echo "$MEMBERS" | wc -l) members in VPN group"
echo ""

# Process each member
CREATED=0
UPDATED=0
SKIPPED=0

while IFS= read -r MEMBER_DN; do
    # Get user details including account status
    USER_INFO=$(ldapsearch -x -LLL -H "${LDAP_SERVER}" \
        -D "${LDAP_BIND_DN}" \
        -w "${LDAP_BIND_PASSWORD}" \
        -b "${MEMBER_DN}" \
        -s base \
        "(objectClass=*)" cn mail sAMAccountName userAccountControl 2>/dev/null)
    
    # Check if account is disabled (userAccountControl bit 2 = ACCOUNTDISABLE)
    UAC=$(echo "$USER_INFO" | grep "^userAccountControl:" | sed 's/^userAccountControl: //')
    if [ -n "$UAC" ]; then
        # Check if bit 2 is set (account disabled)
        if [ $((UAC & 2)) -eq 2 ]; then
            echo "  ⚠ Skipping disabled account: $MEMBER_DN"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
    fi
    
    # Extract username (sAMAccountName or cn)
    USERNAME=$(echo "$USER_INFO" | grep "^sAMAccountName:" | sed 's/^sAMAccountName: //' | head -1)
    if [ -z "$USERNAME" ]; then
        USERNAME=$(echo "$USER_INFO" | grep "^cn:" | sed 's/^cn: //' | head -1)
    fi
    
    # Extract email
    EMAIL=$(echo "$USER_INFO" | grep "^mail:" | sed 's/^mail: //' | head -1)
    
    if [ -z "$USERNAME" ]; then
        echo "  WARNING: Could not extract username from $MEMBER_DN, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    
    # Clean username (remove spaces, convert to lowercase)
    USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '.' | tr -cd '[:alnum:]._-')
    
    # Check if identity already exists
    if ziti edge list identities "name=\"${USERNAME}\"" 2>/dev/null | grep -q "${USERNAME}"; then
        echo "  ✓ Identity exists: ${USERNAME}"
        # Update identity to ensure it has vpn-users tag and is enabled
        ziti edge update identity "${USERNAME}" -a vpn-users > /dev/null 2>&1
        UPDATED=$((UPDATED + 1))
    else
        echo "  + Creating identity: ${USERNAME}"
        # Create new identity
        JWT_FILE="${ZITI_HOME}/enrollments/${USERNAME}.jwt"
        mkdir -p "${ZITI_HOME}/enrollments"
        
        ziti edge create identity user "${USERNAME}" \
            -a vpn-users \
            -o "${JWT_FILE}" > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            echo "    JWT saved: ${JWT_FILE}"
            CREATED=$((CREATED + 1))
        else
            echo "    ERROR: Failed to create identity"
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
    
done <<< "$MEMBERS"

echo ""
echo "========================================="
echo "Synchronization Summary"
echo "========================================="
echo "  Created: $CREATED"
echo "  Updated: $UPDATED"
echo "  Skipped: $SKIPPED"
echo "  Total processed: $((CREATED + UPDATED + SKIPPED))"
echo ""
echo "Completed: $(date)"
echo "========================================="
