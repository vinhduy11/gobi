<p align="center">
  <img src="ui/macos/Resources/AppIcon.svg" alt="Gobi" height="96">
</p>

<p align="center">
  <b>Gobi</b> — a Go IDE, native on macOS.
</p>

<p align="center">
  <a href="https://github.com/vinhduy11/gobi/releases/latest"><b>Download</b></a>
  &nbsp;·&nbsp;
  <a href="#features">Features</a>
  &nbsp;·&nbsp;
  <a href="#benchmark">Benchmark</a>
  &nbsp;·&nbsp;
  <a href="#build-and-run">Build and run</a>
  &nbsp;·&nbsp;
  <a href="#architecture">Architecture</a>
</p>

<p align="center">
  <video src="https://github.com/vinhduy11/gobi/raw/main/docs/assets/gobi-demo.mp4" width="900" controls muted></video>
</p>

<p align="center">
  <a href="docs/assets/gobi-demo.mp4">Watch the 83-second demo</a>: typing with gopls help, Run, a failing test, the fix,
  the debugger, Git, the profiler and Find in Files.
</p>

> **Alpha.** Gobi is new and has not been fully tested yet. Expect rough edges, and please
> [open an issue](https://github.com/vinhduy11/gobi/issues) when something breaks.

Gobi is a client of the official Go toolchain: gopls (LSP), Delve (DAP), `go test` / `go vet`, pprof,
gofmt / goimports and `go.work`. It does not reimplement any of them.

A Go daemon (`gobid`) supervises the tools; a native Swift / AppKit app draws the editor and the tool windows.
macOS first; Windows and Linux UIs come later next to it.

## Features

- **Editor**: gopls code insight (completion with snippets, signature help, hover, go to definition and
  implementation, find references, rename, code actions, organize imports, format on save), code lens, a gutter with
  breakpoints, git marks and Run buttons on tests, JSON and Markdown built in (syntax errors, formatting, outline,
  live preview).
- **Run and test**: Run, Run Tests, Run Test at Cursor, Run on Multiple Go Versions, build and rebuild; output with
  clickable `file:line` links; a Tests tree with filter and jump to the failing line; Go version per project
  (installs from go.dev with `golang.org/dl`); environment profiles with secrets kept in the Keychain and `.env` files.
- **Debug and profile**: Delve debugger with breakpoints (conditions), watches, goroutines, attach, inline values;
  pprof profiler with flame graph, Top table, per-line source cost, filter, compare two profiles, and capture from a
  running program.
- **Git**: status and gutter marks, changes, diff, log, stage, commit, branches, merge, rebase, stash, tags, reset,
  patches, remotes, worktrees, push, pull, fetch, discard; a full Git menu.
- **Terminal and search**: terminal tabs and split, Find in Files with replace (one match, one file or all), search
  history, Go to File, Command Palette.
- **Safe by default**: Restricted Mode for projects you have not trusted, unsaved edits recovered after a crash,
  changes made on disk by other programs noticed and never overwritten silently.
- **Settings**: editor, languages, keymap, terminal, git and advanced tabs, applied live.

## Benchmark

Typing in a 100,000-line, 4.9 MB Go file (`gobi-bench`, release build, Apple Silicon Mac, medians):

|                                      | Gobi        | Budget  |
| ------------------------------------ | ----------- | ------- |
| Open the file (indexes and text)     | **214 ms**  | 300 ms  |
| Keystroke: edit, indexes and layout  | **3.1 ms**  | 16 ms   |

Run it yourself: `cd ui/macos && swift build -c release --product gobi-bench && .build/release/gobi-bench`.
There is no comparison with other IDEs yet. Measurements and what was learnt:
[`docs/architect/ui-macos-spike.md`](docs/architect/ui-macos-spike.md).

## Build and run

Requirements: Go 1.26 or newer, and gopls and Delve installed explicitly (Gobi never installs tools on its own):

```bash
go install golang.org/x/tools/gopls@v0.24.0
go install github.com/go-delve/delve/cmd/dlv@v1.27.2
```

Tested with gopls v0.24.0 and Delve 1.27.2. gopls v0.24.0 needs Go 1.27 to build, so `go install` may switch to a
newer toolchain automatically (`GOTOOLCHAIN=auto`).

macOS app:

```bash
cd ui/macos
./scripts/test.sh                      # Swift tests (works with the Command Line Tools only)
./scripts/make-app.sh                  # builds dist/Gobi.app with gobid bundled, signed ad hoc
./scripts/make-dmg.sh                  # packs dist/Gobi-<version>.dmg (drag to Applications)
open dist/Gobi.app                     # Welcome window: Open… a folder, or pick a recent project
```

The app is signed ad hoc, so on another Mac use right click > Open the first time. A release build is signed with
`SIGN_IDENTITY=… ./scripts/make-app.sh` and notarized with `./scripts/notarize.sh`.

Core (`gobid`):

```bash
cd core
go test -race ./...
go run ./cmd/gobid doctor     # reports go, gopls and dlv locations and versions; exits 1 if a required tool is missing
go run ./cmd/gobid serve      # serve the channels on a private unix socket (-dir to choose the directory)
```

`gobid` allows one instance per socket directory. A workspace is untrusted unless the client says otherwise in the
handshake; untrusted workspaces run gopls with `GOTOOLCHAIN=local` and cannot run code.

## Architecture

- `core/`: `gobid`, a cross-platform Go daemon. It supervises gopls and the other tools and talks to the UI over a local
  socket with channels for language server, terminal, run, git, debug and control requests.
- `ui/macos/`: native Swift / AppKit UI, in layers (model, client, editor, app) checked by `scripts/check-layers.sh`.
- `docs/`: architecture, plans, diagrams, mockups and per-implementation reports.

Further reading: [layers](docs/architect/layers.md), [wire protocol](docs/architect/wire-protocol.md),
[open work](docs/implement/ui-mock-gap.md), [changelog](CHANGELOG.md).

## Tests

```bash
cd core && go vet ./... && go test -race ./...
cd ui/macos && ./scripts/test.sh && ./scripts/check-layers.sh
./scripts/ci.sh                        # everything above in one go (what CI runs)
```

The app also has quiet self-tests that drive the real UI without putting a window in front:
`GobiApp FOLDER --selftest-session` and its siblings (`-run`, `-debug`, `-git`, `-find`, `-env`, `-settings`,
`-toolchain`, `-profile`, `-terminal`, `-setup`, `-lang`, `-codehelp`, …). Each needs a small fixture folder described
above its function in `AppDelegate.swift`.

## Status

Alpha. Built: the core and the macOS app described above, tested by unit tests and the app's own self-tests but not yet by
enough real-world use. Not done yet: VoiceOver and trackpad checks, signing with a real
identity and a CI run, the Windows and Linux UIs, highlighting of Find matches in the terminal.

## License

[GPL-3.0](LICENSE).

<sub>Not affiliated with Google. Go is a trademark of Google LLC.</sub>
