# Releases and versions

## Version numbers

Gobi uses [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`, with an optional pre-release part.

- `0.1.0-alpha.1`, `0.1.0-alpha.2` … : alpha, not fully tested. Then `beta.N`, then `rc.N`, then `0.1.0`.
- Before 1.0.0 a MINOR bump may break things (settings, wire protocol, file formats); PATCH is for fixes only.
- The single source of truth is the `VERSION` file at the repository root. Everything else reads it:
  - `Gobi.app`: `CFBundleShortVersionString` is the version; `CFBundleVersion` is the **build number** (the number of commits, so
    two builds of different commits never share one); `GobiGitCommit` is the short commit (`-dirty` when the tree had uncommitted
    changes). About Gobi shows `0.1.0-alpha.1 (build 26, abc1234)`.
  - `gobid`: `gobid version` prints `gobid 0.1.0-alpha.1 (abc1234)`; a build without the flags prints `gobid dev`.
  - The DMG is named `Gobi-<version>.dmg` and has a `Gobi-<version>.dmg.sha256` next to it.
- Git tags are `v<version>` (`v0.1.0-alpha.1`), annotated, on `main`.

## Branches

`develop` is where finished work is integrated; `main` holds what is released. Releases are cut on `main`
(see `docs/claude/rule.md` for the branch rules).

## Cutting a release

1. Make sure the work is merged into `develop`, then `develop` into `main` (fast-forward), and that every user-visible change has
   an entry under `## [Unreleased]` in `CHANGELOG.md` (Added / Changed / Fixed / Removed).
2. On a clean `main`: `scripts/release.sh 0.1.0-alpha.2` (add `--dry-run` first to see what it will do).
   It checks the version is valid and higher than the current one, writes `VERSION`, turns `[Unreleased]` into
   `## [0.1.0-alpha.2] - <date>` with the compare links, commits `Release 0.1.0-alpha.2` and makes the tag `v0.1.0-alpha.2`.
   It never pushes.
3. Push: `git push origin main v0.1.0-alpha.2`. Pushing the tag starts `.github/workflows/release.yml`, which runs `scripts/ci.sh`,
   builds the app and DMG, writes the notes and publishes the GitHub release (a pre-release for alpha, beta, rc); steps 4 to 6 are
   then only needed for a local or signed/notarized build. `.github/workflows/ci.yml` runs `scripts/ci.sh` on pushes and pull requests.
4. Build from the tagged commit: `ui/macos/scripts/make-app.sh` then `ui/macos/scripts/make-dmg.sh` (output in `dist/`).
   For a build other people can open without the right-click workaround, sign with `SIGN_IDENTITY=… make-app.sh` and run
   `ui/macos/scripts/notarize.sh` before `make-dmg.sh`.
5. Release notes: `scripts/release-notes.sh 0.1.0-alpha.2` writes `dist/RELEASE_NOTES-0.1.0-alpha.2.md`: a summary line, a
   Download table with checksum links, "Already installed?", "What's new" (the CHANGELOG section), "All changes" (the commits since the
   previous tag) and the Full Changelog compare link. Read it and edit it if you want a shorter "What's new".
6. Publish: `scripts/publish-release.sh 0.1.0-alpha.2` (needs the GitHub CLI: `brew install gh && gh auth login`). A version with
   a pre-release part is published as a **pre-release**. Without `gh`, create the release on GitHub by hand: choose the tag, paste
   the notes file, attach the DMG and its `.sha256`, tick "Set as a pre-release" for alpha, beta and rc.
7. Merge `main` back into `develop` so the release commit is on both.

## Tracking what is installed

- In the app: Gobi > About Gobi.
- From a terminal: `/Applications/Gobi.app/Contents/MacOS/gobid version`.
- Which commit a build came from: the commit in the version line (`abc1234`); `-dirty` means it was built with uncommitted changes
  and cannot be reproduced from that commit alone.
