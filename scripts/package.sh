#!/bin/bash
# Builds a universal Lilt.app and wraps it in a drag-to-install disk image under build/.
# The app is ad-hoc signed, not notarized: other Macs will ask the user to allow it once.
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 ./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Lilt.app/Contents/Info.plist)
STAGE="$PWD/build/dmg"
DMG="$PWD/build/Lilt-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto keeps the signature and extended attributes that cp -R can drop.
ditto build/Lilt.app "$STAGE/Lilt.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lilt $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
shasum -a 256 "$DMG"
