#!/bin/bash
# Builds, zips and publishes a GitHub release. The app updates itself from it.
#   ./release.sh 0.2.1 "What changed"
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh <version> [notes]}"
NOTES="${2:-Oneshot $VERSION}"
BUILD=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
./build.sh
mkdir -p dist
ditto -c -k --keepParent build/Oneshot.app dist/Oneshot.zip
git add Resources/Info.plist
git commit -qm "Release $VERSION" || true
git tag -f "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" dist/Oneshot.zip --title "Oneshot $VERSION" --notes "$NOTES"
echo "Released $VERSION"
