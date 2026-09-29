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
# Notarize with Apple so Gatekeeper opens the app without warnings.
# Credentials live in the login keychain: xcrun notarytool store-credentials oneshot-notary --apple-id … --team-id 8W296T4QJG
if grep -q "Developer ID" build/.signed-with && xcrun notarytool history --keychain-profile oneshot-notary >/dev/null 2>&1; then
  xcrun notarytool submit dist/Oneshot.zip --keychain-profile oneshot-notary --wait
  xcrun stapler staple build/Oneshot.app
  rm -f dist/Oneshot.zip
  ditto -c -k --keepParent build/Oneshot.app dist/Oneshot.zip
  spctl -a -vv -t exec build/Oneshot.app
elif [ "${ALLOW_UNNOTARIZED:-}" != 1 ]; then
  echo "Not signed with Developer ID or notary.env missing. Set ALLOW_UNNOTARIZED=1 to release anyway." >&2; exit 1
fi
git add Resources/Info.plist
git commit -qm "Release $VERSION" || true
git tag -f "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" dist/Oneshot.zip --title "Oneshot $VERSION" --notes "$NOTES"
echo "Released $VERSION"
