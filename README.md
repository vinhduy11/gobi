# Gobi

A Go IDE, macOS first. Gobi is a client of the official Go toolchain: gopls (LSP), Delve (DAP),
`go test` / `go vet`, pprof, gofmt / goimports and `go.work`. It does not reimplement any of them.

## Architecture

- `core/`: `gobid`, a cross-platform Go daemon. It supervises gopls and the other tools and talks to the UI
  over a local socket.
- `ui/macos/`: native Swift / AppKit UI. `ui/windows/` and `ui/linux/` come later, next to it.
- `docs/`: architecture, plans, diagrams, artifacts and per-implementation reports.

## Requirements

- Go 1.26 or newer
- gopls and Delve, installed explicitly (Gobi never installs tools on its own):

```bash
go install golang.org/x/tools/gopls@v0.24.0
go install github.com/go-delve/delve/cmd/dlv@v1.27.2
```

Tested with gopls v0.24.0 and Delve 1.27.2. gopls v0.24.0 needs Go 1.27 to build, so `go install` may switch to a
newer toolchain automatically (`GOTOOLCHAIN=auto`).

## Commands

```bash
cd core
go test -race ./...
GOBI_REAL_GOPLS=1 go test -run TestRealGopls ./internal/daemon   # opt-in: real gopls round trip
go run ./cmd/gobid doctor     # reports go, gopls and dlv locations and versions; exits 1 if a required tool is missing
go run ./cmd/gobid serve      # serve the lsp channel on a private unix socket (-dir to choose the directory)
```

JSON and Markdown are handled by a built-in language service (`gobid langserver`, started automatically): JSON syntax
errors, formatting and outline; Markdown outline and an HTML preview request. No extra tool to install.

`gobid` allows one instance per socket directory. A workspace is untrusted unless the client says otherwise in the
handshake; untrusted workspaces run gopls with `GOTOOLCHAIN=local`.

## macOS app (spike)

```bash
cd ui/macos
./scripts/test.sh                      # Swift tests (works with the Command Line Tools only)
./scripts/make-app.sh                  # builds dist/Gobi.app with gobid bundled, signed ad hoc
./scripts/make-dmg.sh                  # packs dist/Gobi-<version>.dmg (drag to Applications)
open dist/Gobi.app                                   # Welcome window: Open… a folder, or pick a recent project
open dist/Gobi.app --args Fixtures/broken/main.go   # a single file
swift build -c release --product gobi-bench && .build/release/gobi-bench    # editor measurements
```

Layers and their rules: `docs/architect/layers.md`. Findings and numbers: `docs/architect/ui-macos-spike.md`. Open work and instructions: `docs/implement/ui-macos-fixes.md`.

```bash
swift build -c release --product gobi-check
.build/release/gobi-check cliff|drag|ax|longline|find|scrollthrough|highlight FILE   # verification harness (modes in its header); quiet, add --visible to watch
python3 scripts/make-fixtures.py OUT_DIR                            # 100k-line and long-line test files
```

## Status

Built: the core (framing, handshake, gopls broker, JSON/Markdown service, run and test, debugger over `dlv dap`, git, pprof,
search, toolchain and environment services) and the macOS app (project window with explorer, tabs, editor, Problems, Tests,
Terminal, Debug, Profiler, Git, Output and Find tabs; Go toolchains and environments; Settings; session restore; changes made
on disk by other programs). Release scripts exist (`make-app.sh` signing with `SIGN_IDENTITY`, `notarize.sh`, `make-dmg.sh`, `scripts/ci.sh`, `.gitlab-ci.yml`) but have not been run with a real signing identity or on a CI runner. Not built: VoiceOver and trackpad checks, Windows and Linux UIs.
Editor keystroke time in `gobi-bench`: about 3 ms on a 100k-line file (budget 16 ms).
See `CHANGELOG.md` and the docs under `docs/implement/` for details.

Self-tests of the app (quiet, no window in front): `GobiApp FOLDER --selftest-session` and its siblings `-run`, `-debug`,
`-git`, `-find`, `-env`, `-settings`, `-toolchain`, `-profile`, `-terminal`, `-setup`, `-lang`, `-codehelp`, `-trust`,
`-newproject`, `-welcome`; each needs a small fixture folder described above its function in `AppDelegate.swift`.
