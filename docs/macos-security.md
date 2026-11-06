# Installing and running Gobi on macOS (builds that are not signed yet)

Alpha builds of Gobi are **signed ad hoc**: the app has a valid code signature that macOS can check for tampering, but it is not
signed with an Apple Developer ID and is not notarized by Apple. macOS therefore treats the download as coming from an
"unidentified developer" and **Gatekeeper blocks the first launch**. This is expected for an unsigned alpha, and it goes away when a
release is signed with a Developer ID and notarized (see `docs/release.md`).

## 1. Check the download

Every release has a `Gobi-<version>.dmg.sha256` file next to the DMG. In the folder that holds both:

```bash
shasum -a 256 -c Gobi-0.1.0-alpha.1.dmg.sha256      # prints "Gobi-0.1.0-alpha.1.dmg: OK"
```

If it does not say OK, do not open the file. Download it again from the release page of the repository.

## 2. Install

Open the DMG and drag **Gobi** onto **Applications**. Eject the disk image.

## 3. Open it the first time

Which steps apply depends on the macOS version.

**macOS 15 (Sequoia) and later, including macOS 26**

1. Double-click Gobi. macOS says it cannot verify Gobi, and offers **Done** (or Move to Trash). Choose **Done**.
2. Open **System Settings > Privacy & Security** and scroll down to **Security**. A line says that "Gobi" was blocked to protect
   your Mac. Click **Open Anyway** and confirm with your password or Touch ID.
3. Open Gobi again and choose **Open** in the last dialog.

Control-click > Open no longer skips this on these versions, so use the Settings route.

**macOS 14 (Sonoma) and earlier**

Right-click (or Control-click) Gobi in Applications, choose **Open**, then **Open** again in the dialog.

You only do this once per installed copy. After an update, a new copy may ask again.

### "Gobi is damaged and can't be opened"

That message means the quarantine flag that browsers put on downloads is set on an app macOS cannot verify. If you trust the
download (you checked the checksum in step 1), remove the flag and open it normally:

```bash
xattr -dr com.apple.quarantine /Applications/Gobi.app
```

This only removes the "downloaded from the internet" mark from Gobi. It does not turn Gatekeeper off for other apps. Do not use
`spctl --master-disable` for this: it switches off the check for every app on the Mac.

To see how macOS judges the app:

```bash
codesign -dv --verbose=2 /Applications/Gobi.app 2>&1 | head -8     # Signature=adhoc for an unsigned alpha
spctl --assess --type execute --verbose=2 /Applications/Gobi.app    # "rejected" until it is signed and notarized
```

## 4. Permission prompts you may see

An ad hoc signature changes with every build, so macOS may ask again after an update. All of these are macOS asking, and you can say
no; a feature that needs the permission will then report it.

| Prompt | Why Gobi asks | If you refuse |
| --- | --- | --- |
| Access to Desktop, Documents or Downloads (and removable or network volumes) | You opened a project in one of those folders | Move the project elsewhere, or allow Gobi under System Settings > Privacy & Security > Files and Folders |
| Keychain access | Environment secrets (Run > Manage Environments) are stored in your login Keychain, never in files | Secrets cannot be read or saved; runs start without them |
| "Gobi would like to find devices on your local network" | A project, or the Go tools it starts, talks to a local server | Only affects programs you run that use the local network |

Gobi does not need Full Disk Access, Accessibility, Screen Recording or Camera and never asks for them.

## 5. What Gobi does on your machine

Knowing this helps you decide what to trust:

- **It runs programs as you.** `go`, `gopls`, `dlv`, `git` and your shell run with your user's rights, as they do in a terminal.
  Running or debugging a project executes that project's code.
- **Restricted Mode.** A folder you have not trusted opens in Restricted Mode: Gobi does not run code, start a terminal or a
  debugger for it, and runs gopls with `GOTOOLCHAIN=local`. Trust a folder only when you trust its contents.
- **Network.** Gobi itself makes two kinds of request: the list of Go releases from go.dev when you open **Install Version** (and
  the download only after you press Install), and profile captures from a program on **this machine** (loopback only). The Go tools
  it starts may download modules, as `go` does in a terminal.
- **Files it writes.** Settings and recent projects in your preferences; unsaved-edit recovery files and logs in
  `~/Library/Application Support/Gobi` and `~/Library/Logs/Gobi` (readable only by you; files that look like secrets, such as
  `.env`, are never kept); profiles and run output in the project's `.gobi/` folder (ignored by git).
- **No usage data.** Gobi has no analytics or crash upload. Crash and error logs stay on your machine; you decide whether to attach
  them to an issue (Help > Copy Diagnostics reduces paths to folder names).
- **Updates.** There is no updater yet. Install a new release by replacing the app in Applications.

## 6. Removing Gobi

Drag Gobi from Applications to the Trash. Its leftovers are `~/Library/Preferences/dev.gobi.app.plist`, the two folders named above,
and the Keychain items "Gobi" (open Keychain Access and search for them).

## For maintainers: making it a signed build

With a Developer ID Application certificate: `SIGN_IDENTITY="Developer ID Application: …" ui/macos/scripts/make-app.sh`, then
`NOTARY_PROFILE=… ui/macos/scripts/notarize.sh`, then `make-dmg.sh`. A notarized build opens without any of the steps in section 3.
