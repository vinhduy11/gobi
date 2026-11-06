#!/bin/bash
# Cuts a release: scripts/release.sh VERSION [--dry-run]
#
#   VERSION  Semantic Versioning without the v, e.g. 0.1.0-alpha.2 or 0.2.0
#
# On a clean `main` it writes VERSION, turns the [Unreleased] section of CHANGELOG.md into "## [VERSION] - date" (and adds the
# compare links at the bottom), commits "Release VERSION" and makes the annotated tag vVERSION. It never pushes: see docs/release.md
# for the steps after it (push, build, release notes, GitHub release).
set -euo pipefail
cd "$(dirname "$0")/.."

NEW=${1:-}
DRY=${2:-}
[ -n "$NEW" ] || { echo "usage: scripts/release.sh VERSION [--dry-run]" >&2; exit 2; }
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ $NEW =~ $SEMVER ]] || { echo "not a Semantic Version: $NEW (expected MAJOR.MINOR.PATCH[-prerelease])" >&2; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || { echo "releases are cut on main (you are on $BRANCH)" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "the working tree has uncommitted changes" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null && { echo "tag v$NEW already exists" >&2; exit 1; }

OLD=$(tr -d ' \n' < VERSION)
REMOTE=$(git remote get-url origin 2>/dev/null || true)
REPO_URL=$(echo "$REMOTE" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
[ -n "$REPO_URL" ] || REPO_URL="https://github.com/OWNER/REPO"
PREV_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
DATE=$(date +%Y-%m-%d)

python3 - "$OLD" "$NEW" "$DATE" "$REPO_URL" "${PREV_TAG:-}" "$DRY" <<'PY'
import re, sys
old, new, date, repo, prev, dry = sys.argv[1:7]

def key(v):
    core, _, pre = v.partition('-')
    nums = tuple(int(x) for x in core.split('.'))
    parts = [] if not pre else [(0, int(p), '') if p.isdigit() else (1, 0, p) for p in pre.split('.')]
    return (nums, 1 if not pre else 0, parts)

# The first release may use the version the VERSION file already has; every later one must be higher.
if not key(new) > key(old) and not (new == old and not prev):
    sys.exit(f"{new} is not higher than the current version {old}")

text = open('CHANGELOG.md').read()
m = re.search(r'^## \[Unreleased\]\n(.*?)(?=^## \[|\Z)', text, re.S | re.M)
if not m or not re.search(r'^- ', m.group(1), re.M):
    sys.exit("CHANGELOG.md has no entries under [Unreleased]")
head = text[:m.start()]
body = m.group(1)
rest = text[m.end():]
# Link references live at the bottom: drop old [Unreleased]/[x.y.z] lines for the tags we rewrite.
links = re.findall(r'^\[[^\]]+\]: .*$', rest, re.M)
rest = re.sub(r'^\[[^\]]+\]: .*\n?', '', rest, flags=re.M).rstrip() + "\n"
links = [l for l in links if not l.startswith('[Unreleased]:') and not l.startswith(f'[{new}]:')]
compare = f"{repo}/compare/{prev}...v{new}" if prev else f"{repo}/releases/tag/v{new}"
links = [f"[Unreleased]: {repo}/compare/v{new}...HEAD", f"[{new}]: {compare}"] + links
out = f"{head}## [Unreleased]\n\n## [{new}] - {date}\n{body.rstrip()}\n\n{rest.rstrip()}\n\n" + "\n".join(links) + "\n"
print(f"CHANGELOG: [Unreleased] becomes [{new}] - {date}; compare link {compare}")
if dry != '--dry-run':
    open('CHANGELOG.md', 'w').write(out)
PY

if [ "$DRY" = "--dry-run" ]; then echo "dry run: VERSION $OLD -> $NEW, tag v$NEW (nothing written)"; exit 0; fi
echo "$NEW" > VERSION
git add VERSION CHANGELOG.md
git commit -q -m "Release $NEW"
git tag -a "v$NEW" -m "Gobi $NEW"
echo "released $NEW locally: commit $(git rev-parse --short HEAD), tag v$NEW (not pushed)"
echo "next: git push origin main v$NEW, then ui/macos/scripts/make-app.sh, make-dmg.sh, scripts/release-notes.sh $NEW, scripts/publish-release.sh $NEW"
