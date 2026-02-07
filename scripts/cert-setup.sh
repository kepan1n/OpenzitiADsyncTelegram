#!/bin/bash
set -e

echo "========================================="
echo "OpenZiti Certificate Setup"
echo "========================================="

# This script prepares custom certificates
# for use with OpenZiti controller and router

CERT_SOURCE_DIR="/certs"
PKI_DIR="${ZITI_HOME:-/persistent}/pki"
CUSTOM_PKI_DIR="$PKI_DIR/custom"

echo "Creating PKI directory structure..."
mkdir -p "$CUSTOM_PKI_DIR/certs"
mkdir -p "$CUSTOM_PKI_DIR/keys"
mkdir -p "$CUSTOM_PKI_DIR/ca"

echo "Checking for required certificate files..."
if [ ! -f "$CERT_SOURCE_DIR/fullchain.cer" ]; then
    echo "ERROR: fullchain.cer not found in $CERT_SOURCE_DIR"
    exit 1
fi

if [ ! -f "$CERT_SOURCE_DIR/cert.key" ]; then
    echo "ERROR: cert.key not found in $CERT_SOURCE_DIR"
    exit 1
fi

if [ ! -f "$CERT_SOURCE_DIR/chain.cer" ]; then
    echo "ERROR: chain.cer not found in $CERT_SOURCE_DIR"
    exit 1
fi

echo "Copying certificate files to PKI structure..."

# Copy the server certificate and key
cp "$CERT_SOURCE_DIR/fullchain.cer" "$CUSTOM_PKI_DIR/certs/server-cert.pem"
cp "$CERT_SOURCE_DIR/cert.key" "$CUSTOM_PKI_DIR/keys/server-key.pem"

# Copy the CA chain
cp "$CERT_SOURCE_DIR/chain.cer" "$CUSTOM_PKI_DIR/ca/ca-chain.pem"

# Set proper permissions
echo "Setting certificate permissions..."
chmod 644 "$CUSTOM_PKI_DIR/certs/server-cert.pem"
chmod 600 "$CUSTOM_PKI_DIR/keys/server-key.pem"
chmod 644 "$CUSTOM_PKI_DIR/ca/ca-chain.pem"

echo "Certificates prepared successfully!"
echo "  Server Certificate: $CUSTOM_PKI_DIR/certs/server-cert.pem"
echo "  Server Key: $CUSTOM_PKI_DIR/keys/server-key.pem"
echo "  CA Chain: $CUSTOM_PKI_DIR/ca/ca-chain.pem"
echo "========================================="
