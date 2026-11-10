#!/bin/sh
# Signs dist/Gobi-<version>.dmg with the release EdDSA key and adds it to appcast.xml on the gh-pages branch, the feed the app checks
# (see docs/architect/auto-update.md). Run by the release workflow after the GitHub release exists, because the appcast points at its DMG.
#
#   SPARKLE_ED_PRIVATE_KEY   the private key as `generate_keys -x FILE` writes it (a GitHub secret). When it is not set the release is
#                            still published but no update is offered, and this says so.
#   GH_TOKEN                 a token that can push to the repository (the workflow's own)
#   APPCAST_DRY_RUN=1        sign and write the appcast into a temporary folder and print it; nothing is pushed
set -eu
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27   # Sparkle-$SPARKLE_VERSION.tar.xz, the tools that sign and verify

VERSION=$(tr -d ' \n' < VERSION)
DMG="dist/Gobi-$VERSION.dmg"
REPO=${GITHUB_REPOSITORY:-vinhduy11/gobi}
if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "::warning::SPARKLE_ED_PRIVATE_KEY is not set: Gobi $VERSION is published but no update is offered (the appcast was not changed)"
    exit 0
fi
[ -f "$DMG" ] || { echo "$DMG is missing" >&2; exit 1; }
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Gobi.app/Contents/Info.plist)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh release download -R sparkle-project/Sparkle "$SPARKLE_VERSION" -p "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$TMP/dl"
echo "$SPARKLE_SHA256  $TMP/dl/Sparkle-$SPARKLE_VERSION.tar.xz" | shasum -a 256 -c -
mkdir "$TMP/sparkle" && tar -xf "$TMP/dl/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$TMP/sparkle"

# The key goes to a file only this user can read, is used, and is gone with the temporary folder.
(umask 077 && printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$TMP/key")
SIGNATURE=$("$TMP/sparkle/bin/sign_update" --ed-key-file "$TMP/key" -p "$DMG")
"$TMP/sparkle/bin/sign_update" --verify --ed-key-file "$TMP/key" "$DMG" "$SIGNATURE" >/dev/null
rm -f "$TMP/key"
LENGTH=$(stat -f%z "$DMG")

if [ "${APPCAST_DRY_RUN:-}" = 1 ]; then
    PAGES="$TMP/pages"; mkdir -p "$PAGES"
else
    PAGES="$TMP/pages"
    gh auth setup-git
    if git ls-remote --exit-code --heads "https://github.com/$REPO.git" gh-pages >/dev/null 2>&1; then
        git clone --quiet --branch gh-pages --single-branch --depth 1 "https://github.com/$REPO.git" "$PAGES"
    else
        git init --quiet -b gh-pages "$PAGES"
        git -C "$PAGES" remote add origin "https://github.com/$REPO.git"
    fi
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/Gobi-$VERSION.dmg"
python3 scripts/appcast.py add --appcast "$PAGES/appcast.xml" --version "$VERSION" --build "$BUILD" --url "$URL" \
    --signature "$SIGNATURE" --length "$LENGTH" --notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
    --date "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

if [ "${APPCAST_DRY_RUN:-}" = 1 ]; then cat "$PAGES/appcast.xml"; exit 0; fi
touch "$PAGES/.nojekyll"
git -C "$PAGES" add appcast.xml .nojekyll
git -C "$PAGES" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit --quiet -m "Appcast: Gobi $VERSION"
git -C "$PAGES" push --quiet origin gh-pages
echo "appcast updated for Gobi $VERSION (build $BUILD)"
