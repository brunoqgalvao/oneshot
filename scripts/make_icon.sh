#!/bin/bash
# Generates Resources/AppIcon.icns from scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift scripts/make_icon.swift "$tmp/icon.png" 2>/dev/null
set=$tmp/AppIcon.iconset
mkdir -p "$set"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$tmp/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
cp "$tmp/icon.png" Resources/AppIcon.png
rm -rf "$tmp"
echo "Wrote Resources/AppIcon.icns"
