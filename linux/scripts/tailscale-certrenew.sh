#!/bin/bash
set -euo pipefail

# Renew Tailscale HTTPS certificates and reload nginx if updated.

CERT_DIR="/var/lib/tailscale/certs"
FQDN=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')

if [[ -z "$FQDN" ]]; then
  echo "ERROR: could not determine Tailscale FQDN" >&2
  exit 1
fi

CERT_FILE="$CERT_DIR/$FQDN.crt"
KEY_FILE="$CERT_DIR/$FQDN.key"

mkdir -p "$CERT_DIR"

# Record mtime before renewal
OLD_MTIME=0
if [[ -f "$CERT_FILE" ]]; then
  OLD_MTIME=$(stat -c %Y "$CERT_FILE")
fi

tailscale cert \
  --cert-file "$CERT_FILE" \
  --key-file "$KEY_FILE" \
  "$FQDN"

NEW_MTIME=$(stat -c %Y "$CERT_FILE")

if [[ "$NEW_MTIME" != "$OLD_MTIME" ]]; then
  echo "Certificate renewed, reloading nginx"
  nginx -t && systemctl reload nginx
else
  echo "Certificate still valid, no renewal needed"
fi
