#!/usr/bin/env bash
#
# scripts/generate-license.sh — Sign a license key for a customer.
#
# Usage:
#   ./scripts/generate-license.sh <email> <transaction_id> [product]
#
# Example:
#   ./scripts/generate-license.sh user@example.com txn_01abc123 noteside
#
# Output: A license key string to send to the customer.
#
# Requires: Python 3 with cryptography package
#   pip3 install cryptography

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <email> <transaction_id> [product]"
    exit 1
fi

EMAIL="$1"
TXN="$2"
PRODUCT="${3:-noteside}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE_KEY_FILE="$SCRIPT_DIR/../keys/license.private.base64"

if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key not found at $PRIVATE_KEY_FILE"
    echo "Run ./scripts/generate-keypair.sh first."
    exit 1
fi

PRIVATE_KEY="$(cat "$PRIVATE_KEY_FILE" | tr -d '[:space:]')"

python3 - "$EMAIL" "$TXN" "$PRODUCT" "$PRIVATE_KEY" <<'PYTHON'
import sys
import json
import base64
from datetime import datetime, timezone
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

email = sys.argv[1]
txn = sys.argv[2]
product = sys.argv[3]
private_key_b64 = sys.argv[4]

private_bytes = base64.b64decode(private_key_b64)
private_key = Ed25519PrivateKey.from_private_bytes(private_bytes)

payload = json.dumps({
    "email": email,
    "txn": txn,
    "product": product,
    "issued": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}, separators=(",", ":"))

payload_bytes = payload.encode("utf-8")
signature = private_key.sign(payload_bytes)

payload_b64 = base64.b64encode(payload_bytes).decode()
signature_b64 = base64.b64encode(signature).decode()

license_key = f"{payload_b64}.{signature_b64}"

print()
print(f"License key for {email}:")
print()
print(license_key)
print()
PYTHON
