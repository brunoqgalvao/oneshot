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

# Keychains used for signing: a Developer ID one (for public releases) or a stable local one.
with_keychain() { # with_keychain <keychain> <password> <command...>
  local kc="$1" pw="$2"; shift 2
  security unlock-keychain -p "$pw" "$kc" 2>/dev/null || return 1
  local orig=()
  while IFS= read -r line; do orig+=("$(echo "$line" | sed -e 's/^ *"//' -e 's/"$//')"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "${orig[@]}" "$kc"
  local rc=0; "$@" || rc=$?
  security list-keychains -d user -s "${orig[@]}"
  return $rc
}
DEVID_KC="$PWD/.signing/devid/devid.keychain-db"
LOCAL_KC="$PWD/.signing/murmur.keychain-db"
signed=""
if [ -f "$DEVID_KC" ]; then
  DEVID=$(security find-identity -p codesigning "$DEVID_KC" | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
  if [ -n "$DEVID" ] && with_keychain "$DEVID_KC" oneshot-devid codesign --force --timestamp --options runtime       --entitlements Resources/Oneshot.entitlements --identifier fm.oneshot.app --sign "$DEVID" "$APP"; then
    signed="$DEVID"
  fi
fi
if [ -z "$signed" ]; then
  [ -f "$LOCAL_KC" ] || ./scripts/make_signing_identity.sh || true
  if [ -f "$LOCAL_KC" ] && with_keychain "$LOCAL_KC" murmur-local codesign --force --sign "Murmur Local Signing"       --identifier fm.oneshot.app "$APP" 2>/dev/null; then
    signed="Murmur Local Signing"
  else
    codesign --force --sign - --identifier fm.oneshot.app "$APP"
    signed="ad-hoc (permissions will need re-granting after each rebuild)"
  fi
fi
echo "Signed: $signed"
echo "$signed" > build/.signed-with

echo "Built $PWD/$APP"
if [ "${1:-}" = "--open" ]; then
  pkill -x Oneshot 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
