#!/bin/bash
# Builds Oneshot.app into ./build. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -v -E "PlatformPath|XCTest" || true
test -x .build/release/Oneshot

[ -f Resources/AppIcon.icns ] || ./scripts/make_icon.sh

APP=build/Oneshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Oneshot "$APP/Contents/MacOS/Oneshot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# ONESHOT_SERVER_URL=https://… ./build.sh points the app at a deployed server.
SERVER_URL="${ONESHOT_SERVER_URL:-$(cat .server-url 2>/dev/null || echo http://localhost:8787)}"
plutil -replace OneshotServerURL -string "$SERVER_URL" "$APP/Contents/Info.plist"
echo "Server: $SERVER_URL"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/google-g.png "$APP/Contents/Resources/google-g.png"

[ -f .signing/murmur.keychain-db ] || ./scripts/make_signing_identity.sh || true
KC="$PWD/.signing/murmur.keychain-db"
signed=0
if [ -f "$KC" ] && security unlock-keychain -p murmur-local "$KC" 2>/dev/null; then
  # codesign only searches keychains on the user search list: add ours just for this call.
  orig=()
  while IFS= read -r line; do orig+=("$(echo "$line" | sed -e 's/^ *"//' -e 's/"$//')"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "${orig[@]}" "$KC"
  codesign --force --sign "Murmur Local Signing" --identifier fm.oneshot.app "$APP" 2>/dev/null && signed=1
  security list-keychains -d user -s "${orig[@]}"
fi
if [ $signed = 1 ]; then
  echo "Signed with stable local identity"
else
  codesign --force --sign - --identifier fm.oneshot.app "$APP"
  echo "Signed ad-hoc (permissions will need re-granting after each rebuild)"
fi

echo "Built $PWD/$APP"
if [ "${1:-}" = "--open" ]; then
  pkill -x Oneshot 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
