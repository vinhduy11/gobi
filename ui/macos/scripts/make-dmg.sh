#!/bin/sh
# Packs dist/Gobi.app into dist/Gobi-<version>.dmg (a drag-to-Applications disk image). Run scripts/make-app.sh first.
# A release build is signed with SIGN_IDENTITY and notarized with scripts/notarize.sh before this step.
set -eu
cd "$(dirname "$0")/.."
DIST="$(cd ../.. && pwd)/dist"   # dist/ is at the repository root
APP="$DIST/Gobi.app"
[ -d "$APP" ] || { echo "dist/Gobi.app is missing: run scripts/make-app.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$DIST/Gobi-$VERSION.dmg"
STAGE=$(mktemp -d "$(pwd)/.build/dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Gobi $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "built $DMG"
cat "$DMG.sha256"
