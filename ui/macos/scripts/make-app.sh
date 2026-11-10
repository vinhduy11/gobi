#!/bin/sh
# Assembles dist/Gobi.app (dist/ is at the repository root) from the release build, bundles gobid next to the app binary, and signs ad hoc.
# SwiftPM builds the executable only; the bundle, Info.plist and signing are done here (works with the
# Command Line Tools alone). Release signing: SIGN_IDENTITY; notarization: scripts/notarize.sh.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIST="$(cd "$ROOT/../.." && pwd)/dist"
APP="$DIST/Gobi.app"
CONTENTS="$APP/Contents"

# One version for everything: the VERSION file at the repository root (Semantic Versioning, e.g. 0.1.0-alpha.1). The build
# number is the number of commits, so every build of a different commit has a different one; the commit goes in too, with
# "-dirty" when the working tree has uncommitted changes.
REPO="$(cd "$ROOT/../.." && pwd)"
VERSION=$(tr -d ' \n' < "$REPO/VERSION")
BUILD=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null)" ] && COMMIT="$COMMIT-dirty"
echo "building Gobi $VERSION (build $BUILD, $COMMIT)"

swift build -c release --product GobiApp
(cd "$ROOT/../../core" && go build -ldflags "-X main.version=$VERSION -X main.commit=$COMMIT" -o "$ROOT/.build/gobid" ./cmd/gobid)

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/GobiApp "$CONTENTS/MacOS/GobiApp"
cp .build/gobid "$CONTENTS/MacOS/gobid"

# Sparkle (updates): the framework SwiftPM fetched, copied with symlinks and permissions kept (ditto). Gobi is not sandboxed, so the XPC
# services are left out. The executable finds the framework through this rpath.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$CONTENTS/Frameworks"
ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
rm -rf "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$CONTENTS/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/GobiApp"
# The appcast and the public half of the EdDSA key that signs the releases (the private half is in the release maintainer's Keychain and
# in the SPARKLE_ED_PRIVATE_KEY secret of the release workflow). Override both to test updates against another feed.
UPDATE_FEED_URL=${UPDATE_FEED_URL:-https://vinhduy11.github.io/gobi/appcast.xml}
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-1BcxRJKgaaAl0KF+iP965bcR0fh7jNVRldlCooigdbg=}

# App icon: render Resources/AppIcon.svg into an iconset, then pack it into AppIcon.icns.
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gobi</string>
    <key>CFBundleDisplayName</key><string>Gobi</string>
    <key>CFBundleIdentifier</key><string>dev.gobi.app</string>
    <key>CFBundleExecutable</key><string>GobiApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>GobiGitCommit</key><string>$COMMIT</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>$UPDATE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Sign the helper first, then the bundle. Ad hoc ("-") is enough to run locally; set SIGN_IDENTITY to a Developer ID
# Application identity (name from `security find-identity -v -p codesigning`) for a release build, which also turns on the
# hardened runtime that notarization requires.
IDENTITY=${SIGN_IDENTITY:--}
OPTIONS=""
# The hardened runtime only with a Developer ID: it turns on library validation, which refuses a framework signed ad hoc by another
# process ("different Team IDs") and Gobi would not start. With one Developer ID on both, the check passes.
[ "$IDENTITY" != "-" ] && OPTIONS="--options runtime --timestamp"
# Inside out, never --deep (it breaks the framework's signatures).
SPARKLE_B="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" $OPTIONS "$SPARKLE_B/Autoupdate"
codesign --force --sign "$IDENTITY" $OPTIONS "$SPARKLE_B/Updater.app"
codesign --force --sign "$IDENTITY" $OPTIONS "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" $OPTIONS "$CONTENTS/MacOS/gobid"
codesign --force --sign "$IDENTITY" $OPTIONS "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP"
