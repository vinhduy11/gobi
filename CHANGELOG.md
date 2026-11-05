# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Repository scaffold.
- `internal/rpc`: LSP base-protocol framing with size limits, strict header validation, fuzz test and benchmark.
- `internal/toolchain` and `gobid doctor`: locate go, gopls and dlv (GOBIN, GOPATH/bin, PATH) and report versions.
- `internal/ipc`: private unix socket (0700 directory, 0600 socket), single-instance lock, stale-socket recovery,
  peer-UID check and a versioned per-channel handshake.
- `internal/lsp`: gopls broker with request-id translation, cancellation, server-request routing, UTF-16 aware document
  tracking and restart with document replay; per-workspace registry; byte-splice id rewriting; `fakelsp` test server.
- `internal/daemon` and `gobid serve`: serve the `lsp` channel; untrusted workspaces run gopls with `GOTOOLCHAIN=local`.
- UI mockups (Edit, Debug, Profile, Environments, Go toolchains, Welcome, New Project, Workspace trust) in `docs/artifact/`.

- `internal/langsvc` and `gobid langserver`: built-in JSON (strict syntax diagnostics, formatting, outline) and
  Markdown (outline, safe HTML preview) language service, served through the same broker as gopls.
- Handshake `language` field and per-language servers in the registry and daemon; unsupported languages are refused.
- Mockups: JSON editing, Markdown preview, menu bar, Settings (Editor, Languages).

- `ui-macos/`: Swift package with a TextKit 2 editor window that shows diagnostics from gobid for Go, JSON and
  Markdown files; LSP client, frame decoder and incremental line index; `gobi-probe`, `gobi-bench`, `make-app.sh`.
- Spike findings in `docs/architect/ui-macos-spike.md`: layout setup that keeps a 100k-line file at 15 ms to open and
  1.7 ms per keystroke.

- `ui-macos/`: syntax colouring for Go, JSON and Markdown (per-line lexers, incremental `SyntaxIndex`, lazy TextKit 2
  rendering attributes), a line-number gutter, shared `GobiEditor` library, mouse, scroll, paint and typing checks in
  `GobiApp --selftest`, and `--snapshot` PNGs. Measured and written up in `docs/architect/ui-macos-spike.md`, including
  the scroller-jump performance cliff and its fix.

- `ui-macos/`: `EditorClipView` maps large scroll jumps to text positions (a 880 ms jump becomes 4 ms and keystrokes after
  it stay at 3.7 ms instead of 205 ms); `gobi-check` verification harness; `scripts/make-fixtures.py`; instructions for the
  remaining editor fixes in `docs/implement/ui-macos-fixes.md`.

### Changed
- `gobid` with no arguments now serves instead of printing usage.
