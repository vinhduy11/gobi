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
go install golang.org/x/tools/gopls@latest
go install github.com/go-delve/delve/cmd/dlv@latest
```

## Status

Early bootstrap: core daemon, gopls broker and tooling checks. See `CHANGELOG.md`.
