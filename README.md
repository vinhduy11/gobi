# Gobi

A Go IDE, macOS first. Gobi is a client of the official Go toolchain: gopls (LSP), Delve (DAP),
`go test` / `go vet`, pprof, gofmt / goimports and `go.work`. It does not reimplement any of them.

## Architecture

- `core/`: `gobid`, a cross-platform Go daemon. It supervises gopls and the other tools and talks to the UI
  over a local socket.
- `ui-macos/`: native Swift / AppKit UI (not created yet). Windows and Linux shells come later.
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
cd ui-macos
./scripts/test.sh                      # Swift tests (works with the Command Line Tools only)
./scripts/make-app.sh                  # builds dist/Gobi.app with gobid bundled, signed ad hoc
open dist/Gobi.app --args Fixtures/broken/main.go
swift build -c release --product gobi-bench && .build/release/gobi-bench    # editor measurements
```

Findings and numbers: `docs/architect/ui-macos-spike.md`.

## Status

Slice 1 (core bootstrap) is implemented: framing codec, tool check, unix-socket transport with handshake, gopls
broker with restart and document replay, and `gobid serve`. The Swift UI, debugger, test runner, environment
profiles, Go version manager, terminal, Git and profiler are designed (see `docs/architect/` and the mockups in
`docs/artifact/`) but not built. See `CHANGELOG.md` and `docs/implement/core-bootstrap.md` for open items.
