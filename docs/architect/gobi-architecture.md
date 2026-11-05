# Gobi architecture

A Go IDE, macOS first, built as a client of the official Go toolchain: gopls (LSP), Delve (DAP), `go test` / `go vet`,
pprof, gofmt / goimports and `go.work`. Gobi does not reimplement any of them.

## Split

- **`gobid`** (`core/`, Go): cross-platform daemon. Supervises gopls and the other tools, owns all tool logic.
- **UI** (`ui/macos/`, Swift/AppKit, not built yet): thin native client, Apple HIG look. Windows and Linux add their own
  shell later and reuse `gobid` unchanged.
- The two talk over a private unix socket. Windows will need a named-pipe transport (`internal/ipc` is unix-only today).

## Transport (`internal/ipc`, `internal/rpc`)

- Framing is the LSP base protocol (`Content-Length`) on every connection, UI to core and core to gopls. The reader
  caps payload size, rejects duplicate, unknown or malformed headers and bare-LF line endings, and is fuzz-tested.
- One connection per channel (`control`, `lsp`, `dap`, `pty`); no multiplexing. Each connection starts with a versioned
  handshake `{protocol, client_version, channel, workspace_root, trusted}`; the core answers accept or reject
  (wrong protocol, unknown channel, channel not served, `lsp` without a workspace root). Only `lsp` is served today.
- Socket: per-user directory (mode 0700, owner and type checked with `lstat`), socket mode 0600, peer UID checked
  with `LOCAL_PEERCRED` / `SO_PEERCRED`, single instance through `flock`, stale-socket recovery that only removes a
  socket we own that nobody answers on, and a short fallback directory when the path would exceed the unix path limit.

## LSP broker (`internal/lsp`)

- One gopls per workspace root and trust level, shared by every window on that workspace (`Registry`); closed when the
  last client leaves.
- The broker is the LSP client of gopls: it runs `initialize` itself (client capabilities kept, process id and workspace
  pinned), answers `shutdown` / `initialized` / `exit`, and keeps the server alive across client disconnects.
- Request ids are translated both ways, `$/cancelRequest` is translated, and a disconnecting client has its requests
  cancelled and its documents closed. Server requests: `workspace/configuration`, capability registration and progress
  creation are answered by the broker; others (`workspace/applyEdit`, `window/showMessageRequest`, ...) go to the
  earliest attached client under a broker-owned id. Notifications are broadcast.
- Open documents are tracked with UTF-16 aware incremental edits. If gopls exits or emits unreadable output, in-flight
  requests fail with a restart error, a new process is started, open documents are replayed with their latest text and
  version, and clients get `gobi/lspRestarted {epoch}`. Retries use linear backoff and end with `gobi/lspFailed`.
- Messages are forwarded as bytes. `peekHeader` reads the top-level `id` and `method` with one scan and `rewriteID`
  splices the new id in; messages with a duplicate `id` or `method` are refused so a client cannot dodge translation.

## Built-in language service (`internal/langsvc`)

JSON and Markdown have no official server worth requiring, so `gobid` ships its own, started as a subprocess
(`gobid langserver`, LSP over stdio) and supervised by the same broker as gopls: restart with document replay, id
translation and sharing between windows all apply. The `lsp` channel handshake carries `language` (`go` default,
`json`, `markdown`); the registry keeps one server per root, language and trust level, and the daemon refuses
languages it has no server for.

- **JSON** (strict): a hand-written parser reports the first syntax error with line and UTF-16 column, builds the
  outline (objects, arrays up to 500 entries, scalar details) and the formatter uses `encoding/json` indentation
  (spaces or tabs from the client's options, one whole-document edit, nothing for invalid or already formatted
  files). A fuzz test keeps the parser's accept/reject decision identical to `encoding/json`.
- **Markdown**: outline from ATX and setext headings outside fenced code, nested by level; request
  `gobi/markdownPreview` returns HTML rendered with goldmark (GFM tables, task lists, strikethrough). Raw HTML and
  dangerous URL schemes are dropped, so the preview can be shown in a web view without scripts.
- Syntax colouring is a UI concern and is not part of the service.
- Sync is full-text; the service advertises it so clients send whole files. Not supported: JSON with comments,
  partial outlines for files with errors, Markdown link and spelling checks.

## Workspace trust

`trusted` comes from the client in the handshake and defaults to false. An untrusted workspace runs gopls with
`GOTOOLCHAIN=local`, so `go` cannot download or switch toolchains there. Broader enforcement (no `go generate`, builds,
tests, terminals, debug launches) belongs to the slices that add those features.

## Performance (measured, Apple silicon, Go 1.26.5)

| Measurement | Result |
|---|---|
| Frame write + read, 4 KB | about 1.4 µs, 7 allocations |
| Rewrite a request id, 8.7 KB completion list | 7.6 µs (was 108 µs with decode and re-encode) |
| Rewrite a request id, 868 KB completion list | 0.7 ms (was 8.3 ms) |
| Read id and method, 868 KB | 0.58 ms (full decode: 4.7 ms) |

These are core-side micro-benchmarks. Swift-side decoding and end-to-end latency are not measured yet.
Budgets (keystroke to paint under 16 ms, 100k-line file open under 300 ms, completion p95 under 100 ms, 50 MB profile
under 2 s, idle RAM excluding gopls under 150 MB) are checked in later slices.

## Not built yet

dlv/DAP channel, `go test` and `go vet` runner, environment profiles, Go toolchain manager (multiple versions),
terminal (`pty`) and Git, pprof aggregation, the Swift UI. The design for these is in the project plan; mockups are in
`docs/artifact/2026-11-05-ui-mockup/`.
