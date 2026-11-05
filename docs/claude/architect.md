# Architecture

- `core/` (Go module `gobi/core`): the `gobid` daemon. One gopls per workspace root, shared by every UI window on it.
  gobid is the LSP client: it owns initialize, request-ID translation, cancellation, server-to-client requests
  and restart with replay of open documents.
- UI processes connect over a unix socket. One connection per channel (`control`, `lsp`, `dap`, `pty`); each opens
  with a versioned handshake. No multiplexing on a single stream.
- Framing is the LSP base protocol (`Content-Length`) on both UI-to-core and core-to-gopls.
- `ui/macos/` is a thin native client; it holds no Go tooling logic.

Full design: `docs/architect/`.
