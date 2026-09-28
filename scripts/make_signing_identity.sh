#!/bin/bash
# Creates a self-signed code-signing identity in a private keychain
# (.signing/murmur.keychain-db). Signing every build with the same identity
# keeps macOS permissions (Accessibility, Microphone) across rebuilds;
# ad-hoc signatures change on every build and silently lose them.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=.signing
KC="$PWD/$DIR/murmur.keychain-db"
PASS=murmur-local
NAME="Murmur Local Signing"
mkdir -p "$DIR"
if [ -f "$KC" ]; then echo "Signing keychain already exists"; exit 0; fi

cat > "$DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- -legacy && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
  -out "$DIR/identity.p12" -passout pass:$PASS

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$DIR/identity.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
rm -f "$DIR/key.pem" "$DIR/identity.p12"
echo "Created signing identity '$NAME' in $KC"
