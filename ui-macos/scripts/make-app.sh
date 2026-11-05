#!/bin/sh
# Assembles dist/Gobi.app from the release build, bundles gobid next to the app binary, and signs ad hoc.
# SwiftPM builds the executable only; the bundle, Info.plist and signing are done here (works with the
# Command Line Tools alone). Developer ID signing and notarization come later.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/dist/Gobi.app"
CONTENTS="$APP/Contents"

swift build -c release --product GobiApp
(cd "$ROOT/../core" && go build -o "$ROOT/.build/gobid" ./cmd/gobid)

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/GobiApp "$CONTENTS/MacOS/GobiApp"
cp .build/gobid "$CONTENTS/MacOS/gobid"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gobi</string>
    <key>CFBundleDisplayName</key><string>Gobi</string>
    <key>CFBundleIdentifier</key><string>dev.gobi.app</string>
    <key>CFBundleExecutable</key><string>GobiApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign the helper first, then the bundle. Ad hoc ("-") is enough to run locally.
codesign --force --sign - "$CONTENTS/MacOS/gobid"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP"
