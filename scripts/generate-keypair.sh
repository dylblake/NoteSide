#!/usr/bin/env bash
#
# scripts/generate-keypair.sh — Generate an Ed25519 key pair for license signing.
#
# Run once. Keep the PRIVATE key secret. Embed the PUBLIC key in
# LicenseValidator.swift (publicKeyBase64).
#
# Outputs:
#   keys/license.private.base64   — 32-byte private key (base64)
#   keys/license.public.base64    — 32-byte public key (base64)
#
# Requires: Python 3 with cryptography package
#   pip3 install cryptography

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/../keys"
mkdir -p "$KEYS_DIR"

python3 - "$KEYS_DIR" <<'PYTHON'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64

keys_dir = sys.argv[1]

private_key = Ed25519PrivateKey.generate()
private_bytes = private_key.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
public_bytes = private_key.public_key().public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)

priv_b64 = base64.b64encode(private_bytes).decode()
pub_b64 = base64.b64encode(public_bytes).decode()

with open(f"{keys_dir}/license.private.base64", "w") as f:
    f.write(priv_b64 + "\n")

with open(f"{keys_dir}/license.public.base64", "w") as f:
    f.write(pub_b64 + "\n")

print(f"Private key: {keys_dir}/license.private.base64")
print(f"Public key:  {keys_dir}/license.public.base64")
print()
print(f"Public key (paste into LicenseValidator.swift):")
print(f"  {pub_b64}")
print()
print("⚠️  Keep the private key SECRET. Never commit it to git.")
PYTHON

# Ensure private key is not committed
GITIGNORE="$SCRIPT_DIR/../.gitignore"
if ! grep -qF "keys/" "$GITIGNORE" 2>/dev/null; then
    echo "keys/" >> "$GITIGNORE"
    echo "Added 'keys/' to .gitignore"
fi

echo
echo "Done. Now paste the public key into LicenseValidator.swift:"
echo "  private static let publicKeyBase64 = \"$(cat "$KEYS_DIR/license.public.base64")\""
