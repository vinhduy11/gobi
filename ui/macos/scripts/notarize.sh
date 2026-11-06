#!/bin/sh
# Notarizes dist/Gobi.app and staples the ticket. Needs a Developer ID build (SIGN_IDENTITY=... scripts/make-app.sh) and a
# notarytool credentials profile stored once in the keychain:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id ... --team-id ...
# Nothing secret is read from or written to this repository.
set -eu
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to the notarytool keychain profile name}"
APP=dist/Gobi.app
ZIP=dist/Gobi.zip
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
echo "notarized $APP"
