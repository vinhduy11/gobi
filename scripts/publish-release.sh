#!/bin/bash
# Creates the GitHub release of a version with the DMG, its checksum and the release notes:
#   scripts/publish-release.sh [VERSION] [--draft]
# Needs the GitHub CLI (`brew install gh`, `gh auth login`), the tag pushed (git push origin main vVERSION) and the files in dist/
# (ui/macos/scripts/make-app.sh, make-dmg.sh, scripts/release-notes.sh). A version with a prerelease part (alpha, beta, rc) is
# published as a pre-release. Publishing is outward-facing: it asks before it creates anything.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(tr -d ' \n' < VERSION)}
DRAFT=""; [ "${2:-}" = "--draft" ] && DRAFT="--draft"
TAG="v$VERSION"
command -v gh >/dev/null || { echo "the GitHub CLI is not installed: brew install gh && gh auth login" >&2; exit 1; }
for file in "dist/Gobi-$VERSION.dmg" "dist/Gobi-$VERSION.dmg.sha256" "dist/RELEASE_NOTES-$VERSION.md"; do
  [ -f "$file" ] || { echo "missing $file" >&2; exit 1; }
done
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || { echo "the tag $TAG is not on origin: git push origin $TAG" >&2; exit 1; }
FLAGS=""; [[ $VERSION == *-* ]] && FLAGS="--prerelease"
echo "about to create the GitHub release $TAG ${FLAGS:+($FLAGS)} ${DRAFT:+(draft)} with:"
ls -lh "dist/Gobi-$VERSION.dmg" "dist/Gobi-$VERSION.dmg.sha256"
read -r -p "create it? [y/N] " answer
[ "$answer" = "y" ] || { echo "cancelled"; exit 1; }
gh release create "$TAG" "dist/Gobi-$VERSION.dmg" "dist/Gobi-$VERSION.dmg.sha256" \
  --title "Gobi $VERSION" --notes-file "dist/RELEASE_NOTES-$VERSION.md" $FLAGS $DRAFT --verify-tag
