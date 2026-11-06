#!/bin/bash
# Writes the release notes of a version to dist/RELEASE_NOTES-VERSION.md and prints the path.
#   scripts/release-notes.sh [VERSION]      (default: the VERSION file)
# Layout (after the GitHub releases of well-run projects): one line of summary, a Download table with checksums, "Already
# installed?", "What's new" from the CHANGELOG section of that version, "All changes" from the git log since the previous tag, and
# the Full Changelog compare link. Run it after scripts/release.sh and the DMG build, from the tagged commit.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(tr -d ' \n' < VERSION)}
TAG="v$VERSION"
REMOTE=$(git remote get-url origin 2>/dev/null || true)
REPO_URL=$(echo "$REMOTE" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
[ -n "$REPO_URL" ] || REPO_URL="https://github.com/OWNER/REPO"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  PREV=$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)
  RANGE=${PREV:+$PREV..}$TAG
  CHANGELOG_REF=$TAG
else
  PREV=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  RANGE=${PREV:+$PREV..}HEAD
  CHANGELOG_REF=HEAD
fi
mkdir -p dist
OUT="dist/RELEASE_NOTES-$VERSION.md"
DMG="Gobi-$VERSION.dmg"
PRERELEASE=""; [[ $VERSION == *-* ]] && PRERELEASE=1

python3 - "$VERSION" "$TAG" "$REPO_URL" "$PREV" "$DMG" "$PRERELEASE" "$RANGE" > "$OUT" <<'PY'
import re, subprocess, sys
version, tag, repo, prev, dmg, pre, rng = sys.argv[1:8]
log = subprocess.run(["git", "log", "--no-merges", "--pretty=%h%x09%s", rng], capture_output=True, text=True).stdout.strip().splitlines()
changelog = open("CHANGELOG.md").read()
m = re.search(rf'^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)', changelog, re.S | re.M)
section = m.group(1).strip() if m else ""
if not section:  # not cut yet: use the Unreleased section
    m = re.search(r'^## \[Unreleased\]\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)', changelog, re.S | re.M)
    section = m.group(1).strip() if m else ""
base = f"{repo}/releases/download/{tag}"
print(f"Gobi {version} is a macOS IDE for Go: gopls code insight, run and test on any installed Go, the Delve debugger, pprof profiling, Git and a terminal, in a native app." )
print()
if pre:
    print("> **Pre-release.** Gobi is alpha software and has not been fully tested yet. Please [open an issue](" + repo + "/issues) when something breaks.")
    print()
print("### Download")
print()
print("| Architecture | macOS |")
print("| --- | --- |")
print(f"| Apple Silicon (arm64) | [{dmg}]({base}/{dmg}) · [sha256]({base}/{dmg}.sha256) |")
print()
print(f"The app is signed ad hoc and not notarized yet: the first time, right-click Gobi and choose **Open**. To verify the download, run `shasum -a 256 -c {dmg}.sha256` next to the DMG.")
print()
print("**Already installed?** Gobi has no updater yet: download the new DMG and replace Gobi in Applications. A newer Gobi replaces the older `gobid` daemon by itself the first time it connects.")
print()
print("## What's new")
print()
if section:
    print(re.sub(r'^### ', '### ', section, flags=re.M))
else:
    print("_See the commit list below._")
print()
print(f"## All changes ({len(log)} commits)")
print()
for line in log:
    h, _, subject = line.partition("\t")
    print(f"- {subject} ([`{h}`]({repo}/commit/{h}))")
print()
if prev:
    print(f"**Full Changelog**: [{prev}...{tag}]({repo}/compare/{prev}...{tag})")
else:
    print(f"**Full Changelog**: [{tag}]({repo}/commits/{tag})")
PY
echo "$OUT"
