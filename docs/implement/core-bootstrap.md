# Slice 1: core bootstrap

Goal: `gobid` serves LSP to local clients through a broker that owns the gopls session.

## Done

1. Repository scaffold: `README.md`, `CHANGELOG.md`, `CLAUDE.md` index and `docs/claude/*`.
2. `internal/rpc`: framing codec, fuzz test, benchmark.
3. `internal/toolchain` and `gobid doctor`.
4. `internal/ipc`: private socket, lock, stale-socket recovery, peer UID, handshake, channel routing.
5. `internal/lsp`: broker (id translation, cancel, server requests, restart with replay), UTF-16 text sync, registry,
   byte-splice id rewriting, scriptable `fakelsp` for tests.
6. `internal/daemon` and `gobid serve`: lsp channel per workspace, untrusted workspaces run with `GOTOOLCHAIN=local`.

## Verification

```bash
cd core
go vet ./... && go test -race ./...
GOBI_REAL_GOPLS=1 go test -run TestRealGopls ./internal/daemon        # real gopls hover round trip
go test -fuzz FuzzRead -fuzztime 30s ./internal/rpc
go test -fuzz FuzzRewriteID -fuzztime 30s ./internal/lsp
go test -run xxx -bench . -benchmem ./internal/rpc ./internal/lsp
go run ./cmd/gobid doctor
```

Manual: start `gobid serve -dir <short dir>`, a second `gobid serve` on the same directory exits with an
"already running" error, and SIGTERM removes the socket.

## Open items before calling slice 1 finished

- Acceptance cases still without a test: `go.work` change reconfiguring gopls, vendor mode, cgo-disabled files and
  per-file build constraints (real-gopls fixtures), and offline with a missing pinned toolchain.
- CI (Go tests and a fuzz smoke on every change) is not set up.
- Dependency and licence review for `golang.org/x/sys` is not written down.
