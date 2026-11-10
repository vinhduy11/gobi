# Auto update

Research, proposal, spike result and what was built (2026-11-10). The first release with updates needs the one-time steps in `docs/release.md`. The Settings > General checkbox "Check for updates automatically" is drawn
disabled ("Gobi has no update server yet").

## What Gobi has today

- A GitHub repository that is **public**, with a release per tag (`v0.1.0-alpha.N`), all of them **pre-releases**, each with
  `Gobi-<version>.dmg` and `Gobi-<version>.dmg.sha256` (built by `.github/workflows/release.yml`).
- A hand-assembled `Gobi.app` (SwiftPM executable plus `make-app.sh`), **signed ad hoc**, **not notarized**. `make-app.sh` accepts a
  Developer ID identity and `notarize.sh` exists, but there is no Apple Developer account behind them yet.
- `CFBundleShortVersionString` = `VERSION` (`0.1.0-alpha.8`); `CFBundleVersion` = number of commits (monotonic on `main`).
- `gobid` outlives the app. `DaemonFreshness` already restarts a daemon that is older than the `gobid` file next to the app.
- Every download of an ad-hoc, un-notarized app is quarantined, so each manual update repeats the "Open Anyway" steps of
  `docs/macos-security.md`.

## Options

| Option | What it is | For | Against |
|---|---|---|---|
| **A. Sparkle 2** | The standard macOS updater: checks an appcast, shows the standard dialogs, downloads, verifies, replaces the app and relaunches | Mature; UI, scheduling, release notes, "install on quit" included; the app downloads the update itself, so **no quarantine and no Gatekeeper prompt** after the first install; accepts the DMG we already publish; EdDSA signature on every update | Docs do not say ad-hoc apps work (see Risks); needs the framework embedded and signed by hand because we do not build with Xcode; an appcast must be hosted; a private signing key to look after |
| B. Own updater | Query the GitHub Releases API, compare versions, download the DMG, check the `.sha256`, replace the app on quit | No dependency | We write and own the hard part (replace a running app, permissions, relaunch, rollback); the `.sha256` comes from the same place as the file, so it proves integrity, not authenticity |
| C. Notify only | "Version X is available" with a button that opens the release page | A day of work; no risk | The user still downloads, mounts, drags and does the Open Anyway steps every time |
| D. Homebrew cask | `brew upgrade --cask gobi` | No in-app work | Needs a tap; Homebrew is phasing out casks that fail Gatekeeper, which un-notarized ones do |

## Recommendation

Sparkle 2. The one question the docs left open (does it work for an ad-hoc app?) was answered by a spike: it does, with the rules
in "Spike result" below.

Why not a Developer ID first? It is the better end state (notarization, no first-launch dance, and the Sparkle docs recommend it),
but it costs an Apple Developer Program membership and is independent: the design below works for ad hoc and for Developer ID, and
only the signing identity changes.

## Design

### In the app
- Add Sparkle as a SwiftPM dependency of `GobiApp` only (the layers stay: Model, Client and Editor do not import it).
- `AppUpdater` (GobiApp): owns an `SPUStandardUpdaterController(startingUpdater: true, ...)`.
- Menu: **Gobi > Check for Updates…**, calling `checkForUpdates(_:)`.
- Settings > General: enable the existing checkbox and bind it to `updater.automaticallyChecksForUpdates`; show the date of the last check.
- Info.plist (written by `make-app.sh`): `SUFeedURL`, `SUPublicEDKey` (public, committed), `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval` (default 86400 s). Without `SUEnableAutomaticChecks` Sparkle asks the user on the second launch.
- Channels: every release is a pre-release, so put alpha, beta and rc items in an appcast channel and let the app opt in with
  `allowedChannels(for:)`; a stable `0.x.y` item has no channel and everyone sees it. A setting "Include pre-releases" decides it.
- Versions: `sparkle:version` = build number (commit count, monotonic), `sparkle:shortVersionString` = `0.1.0-alpha.8`. Sparkle
  compares the build number, so release builds must come from the tagged commit with full history (the workflow already does
  `fetch-depth: 0`).

### Packaging (`make-app.sh`)
- Copy `Sparkle.framework` into `Contents/Frameworks`, **preserving symlinks and permissions**; add rpath `@loader_path/../Frameworks`.
- Sign inside-out, never with `--deep`: `Autoupdate`, `Updater.app`, the XPC services if kept, then the framework, then `gobid`, then
  the app. Gobi is not sandboxed, so the XPC services are optional: the Sparkle docs say the Installer service is required for
  sandboxed apps only; keep them off unless the spike shows a need.

### Release pipeline (`release.yml`)
1. Build the DMG as today.
2. `sign_update Gobi-<v>.dmg` with the private EdDSA key (a GitHub secret holding the exported key) gives `sparkle:edSignature` and the length.
3. Append an `<item>` (version, short version, channel, release notes link, enclosure URL of the GitHub release asset, signature,
   length) to `appcast.xml`.
4. Publish `appcast.xml` on **GitHub Pages** (a `gh-pages` branch). `releases/latest/download/appcast.xml` does not work: `latest`
   skips pre-releases and all of ours are.

### The daemon
Sparkle quits the app, replaces the bundle and relaunches. The old `gobid` keeps running from the replaced file until the new app
starts, finds the new `gobid` newer than the daemon (`DaemonFreshness`) and restarts it. That ends running terminals and debug
sessions, so the update dialog should say so, and the app should ask before installing while a run or terminal is busy.

### Keys
`generate_keys` stores the private key in the login Keychain and prints the public key. The private key is the only proof of
authenticity for an ad-hoc app: keep an offline backup, store it as a CI secret only, and never commit it. A lost key means users
must install a new build by hand; a leaked key means anyone can ship updates.

## Spike result

Sparkle 2.10.1 (SwiftPM, `from: "2.10.1"`) embedded in a copy of the app built like `make-app.sh`: signed **ad hoc**, not sandboxed,
XPC services removed, framework copied with `ditto`, rpath `@executable_path/../Frameworks` added with `install_name_tool`, signed
inside-out (`Autoupdate`, `Updater.app`, the framework, `gobid`, the app). Two builds (build 100 and 200), the second as a DMG signed
with `sign_update`, an `appcast.xml` and `python3 -m http.server` on localhost. The updater ran with the same settings the real app would
use (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`).

| Test | Result |
|---|---|
| Embedded Sparkle loads in an ad-hoc app, reads the appcast, finds the update | Works |
| Download the DMG, verify the EdDSA signature, extract, install when the app quits | **Installed**: version and build changed (0.1.0-spike.1 / 100 to 0.1.0-spike.2 / 200); the app bytes equal the second build |
| After the update | Signature valid, **no quarantine attribute** (only `com.apple.provenance`), the app starts as the new version and reports "up to date" |
| A valid signature of other bytes in the appcast | **Refused** ("improperly signed", error 4005); nothing installed |
| Genuine signature, DMG tampered in one byte | **Refused**; nothing installed |
| Appcast item with no signature, app has `SUPublicEDKey` | **Refused**; nothing installed |
| Ad hoc **with the hardened runtime** (`--options runtime`) | **The app does not start**: dyld "not valid for use in process ... different Team IDs" (library validation) |
| The same plus entitlement `com.apple.security.cs.disable-library-validation` | Starts; Sparkle works |

So EdDSA is enough for an ad-hoc app, and it is what protects the update: a bad or missing signature never installs. Rules that follow:

1. Do not use the hardened runtime with an ad-hoc build. If a build must use it (a Developer ID release does), a Developer ID gives the
   framework and the app the same Team ID and library validation passes; ad hoc needs the entitlement above.
2. Keep the XPC services out: Gobi is not sandboxed and the updater worked without them.
3. Check the ad-hoc signature of the **new** bundle is not compared with the old one: it changed with every build and the update still installed.

Not covered, and to test on the first real build:

- The interactive path (the "Install Update" dialog and "Install and Relaunch"). It could not be driven here (no Accessibility
  permission for scripting). It uses the same installer as the path tested, but the dialog and the relaunch were not exercised.
- An install into `/Applications` (the spike installed into a user-owned folder). Sparkle asks for authorization when the folder is not writable.
- Updating from a DMG hosted on GitHub over HTTPS (the spike used HTTP on localhost) and the appcast on GitHub Pages.
- The effect on `gobid` and running terminals.

Cleanup done: the throwaway key was removed from the Keychain and the key file deleted; no spike code is in the repository.

## Risks that remain

1. The private EdDSA key is now the only proof of authenticity. Lost: users install by hand once. Leaked: anyone can ship updates.
2. The interactive dialog flow and an install into `/Applications` are untested (above).
3. Not sandboxed, so the XPC services are not used: a path fewer people run, but it worked here.

## Built

Sparkle 2.10.1 as a dependency of `GobiApp`; `AppUpdater` (a thin wrapper); Gobi > Check for Updates…; Settings > General (automatic checks,
Include pre-releases, last check); `make-app.sh` embeds the framework, adds the rpath, signs inside-out and writes the Info.plist keys;
`UpdateChannel` and `GeneralSettings.includePrereleases` (tested); `scripts/appcast.py` (tested), `scripts/publish-appcast.sh`, the
workflow step, and `scripts/sparkle-key.sh`. Checked end to end with the real app: built with a local feed, it fetched the appcast,
downloaded, verified and installed the next build when it quit.

## Work from here (the plan before it was built)

| Step | Size |
|---|---|
| Sparkle dependency, `AppUpdater`, menu item, Settings checkbox and "Include pre-releases" | 0.5 day |
| `make-app.sh`: embed, rpath, inside-out signing (no hardened runtime for ad hoc), Info.plist keys | 0.5 day |
| `release.yml`: sign, appcast item, Pages publish; a script with tests for the appcast item | 1 day |
| Docs (`release.md`, `macos-security.md`), changelog, an end-to-end update from the previous release | 0.5 day |

## Sources

Sparkle: [documentation](https://sparkle-project.org/documentation/), [security and reliability](https://sparkle-project.org/documentation/security-and-reliability/),
[publishing an update](https://sparkle-project.org/documentation/publishing/), [sandboxing](https://sparkle-project.org/documentation/sandboxing/),
[programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [repository](https://github.com/sparkle-project/Sparkle).
