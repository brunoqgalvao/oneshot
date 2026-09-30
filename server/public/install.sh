#!/bin/sh
# Installs the latest Oneshot into /Applications (or ~/Applications).
#   curl -fsSL https://oneshot.agenturl.dev/install.sh | sh
set -e
URL="https://github.com/brunoqgalvao/oneshot/releases/latest/download/Oneshot.zip"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
TMP="$(mktemp -d)"
echo "Downloading Oneshot…"
curl -fsSL "$URL" -o "$TMP/Oneshot.zip"
ditto -x -k "$TMP/Oneshot.zip" "$TMP"
pkill -x Oneshot 2>/dev/null || true
rm -rf "$DEST/Oneshot.app"
mv "$TMP/Oneshot.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Oneshot.app" 2>/dev/null || true
rm -rf "$TMP"
open "$DEST/Oneshot.app"
echo "Oneshot is installed in $DEST. Follow the setup, then hold the left Option key (⌥) and talk."
