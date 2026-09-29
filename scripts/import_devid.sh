#!/bin/bash
# Puts the Developer ID key + certificate into a private keychain used only by build.sh.
#   scripts/import_devid.sh path/to/developerID_application.cer
set -euo pipefail
cd "$(dirname "$0")/.."
D=.signing/devid
CER="${1:?usage: scripts/import_devid.sh developerID_application.cer}"
KC="$PWD/$D/devid.keychain-db"
PW=oneshot-devid
[ -f "$KC" ] || security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$D/DeveloperIDG2CA.cer"
security import "$D/DeveloperIDG2CA.cer" -k "$KC" 2>/dev/null || true
# codesign builds the chain from the login keychain, so the (public) Apple intermediate must live there too.
security import "$D/DeveloperIDG2CA.cer" -k "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
security import "$D/devid.key" -k "$KC" -T /usr/bin/codesign 2>/dev/null || true
security import "$CER" -k "$KC" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
security find-identity -v -p codesigning "$KC"
