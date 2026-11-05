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

- `ui-macos/`: find in file (own find bar, Edit > Find, Find Next, Find Previous, Use Selection for Find); files with a line over 550,000 characters open read-only with a notice; the scroller thumb now moves the text while dragging (throttled live jumps); `gobi-check scrollthrough`; mockups for the find bar and the read-only notice.

- `ui-macos/`: IDE shell. Welcome window (Open…, recent projects), project window with a file explorer beside the editor, workspace trust dialog (Trust and Open / Open in Restricted Mode / Cancel, optional parent folder), project kind (workspace, module, folder) in the title, trust passed to gobid. File > Open (⌘O) takes a folder, go.mod, go.work or a single file. `GobiApp FOLDER --selftest` checks the explorer and opening a file. Pure model (`ProjectKind`, `FileTree`, `RecentProjects`, `TrustList`) with tests.

- `ui-macos/`: editor tabs in the project window (open, switch, close with ⌘W, next/previous with ⇧⌘] and ⇧⌘[, middle-click closes), unsaved-changes dot and window edited mark, File > Save (⌘S), save prompts on closing a tab or window. Pure `TabStrip` model with tests; project self-test checks tabs, dirty state and save (`--allow-writes`). Several files open at once as tabs: select them in the explorer (shift/command-click) or choose them in File > Open.
- `internal/project` and the `control` channel: `project/new` (templates cli, library, http, empty, workspace; name, location, module path, Go version, `git init` on master, README and `.gitignore`), `project/open` (kind and module path), `project/clone` (user's `git`; only https, ssh, git and scp-style URLs; ext:: and local paths refused), `project/import` (adds `go.mod`, module path from the git remote or folder name). A project is never written into a folder that already has files; `go` runs with `GOTOOLCHAIN=local`.

- `ui-macos/`: New Project (⇧⌘N), Clone Repository (⇧⌘K) and Import Existing Code dialogs, also on the Welcome window; they call gobid's `project/*` requests through `ControlClient`. A project you create is trusted automatically; a clone or import still asks. Form checks in `ProjectForm` with tests; `gobi-check project DIR` exercises the requests against a real gobid. Mockup board for the Clone and Import dialogs.

- `ui-macos/`: at launch the newest recent project reopens (in Restricted Mode, without a question, when it was never trusted). The Welcome window shows when there is no recent project or Option is held while opening the app.
- `ui/macos/`: app icon (the G as the sun over dunes). `Resources/AppIcon.svg` is the source; `scripts/make-icon.swift` renders the iconset and `make-app.sh` packs it into `Gobi.app`. The other candidates stay in `Resources/icon-candidates/`.

- `ui/macos/`: File > Open Recent (ten newest projects, same-name folders told apart by their parent, Clear Menu); several files dropped on the Dock icon or passed to `open` open as tabs of the project that holds them, reopening a recent project when needed; the Welcome window shows the app icon.

### Fixed
- `ui/macos/`: the tabs were never visible. The tab strip was a stack used as a scroll view's document view without constraints, so every tab had size 0 by 0. It is pinned now, has a background of its own with a hairline, and the project self-test checks that each tab is drawn with a real size (and writes a window snapshot with `--snapshot`).
- `ui-macos/` and `core/`: a lone `\r` is a line break in `LineIndex`, `lsp` text sync and `langsvc` positions, as the protocol defines.
- `ui-macos/`: `GobiApp --selftest` and `gobi-check` run quietly (no window, focus change or Dock icon); `--visible` shows the window.
- `ui-macos/`: syntax colours no longer go stale or sit at the wrong offset after an edit (closing `/* */`, typing in
  front of a keyword, replacing the text). TextKit ran the colouring validator while it was still synchronising the edit
  and then shifted the colours just written by the edit's length; the editor now recolours the changed lines in the
  viewport once the edit is fully processed (`EditorContentStorage`, `SyntaxHighlighter.recolourAfterEdit`).
- `ui-macos/`: `gobi-check highlight` read a neighbouring run's colour for uncoloured text; it now checks the run that
  contains the offset, checks that token colours line up with the tokens, and writes PNGs of the editor with `--png-dir`.
- `ui-macos/`: a diagnostic underline no longer removes the syntax colour of the text under it (underlines now add and
  remove only their own rendering attributes through the shared `DiagnosticUnderlines`).
- `ui-macos/`: paint measurements (self-test, `gobi-bench`, `gobi-check`) use `flushPendingPaint()` (`CATransaction.flush`)
  instead of `displayIfNeeded()`, which paints nothing here; the self-test checks the gutter is painted per keystroke.
- `ui-macos/`: an LSP request that times out no longer leaves its pending entry behind; a late response is dropped.
- `ui-macos/`: VoiceOver line queries (insertion-point line, line for index, range for line) are answered from `LineIndex`
  by `EditorTextView`; the 100k-line file went from 7.9 s to under 0.01 ms for the caret line, and keystrokes after the
  queries from 220 ms to 3.8 ms.
- `ui-macos/`: lines over 20,000 characters are not syntax coloured (their keystroke cost drops from about 13 s to about 150 ms
  on a 1 MB line), and the status line says so.
- `ui-macos/`: dragging the scroller thumb no longer lays out every place the drag passes. Big jumps are deferred until the
  drag ends and applied once (trade-off: the text does not follow the thumb while dragging). Keystrokes after a full drag of
  a 100k-line file go from 10.4 ms to 2.1 ms, and memory growth from +139 MB to +26 MB.
- `ui-macos/`: `GobiApp FILE --selftest` exits with code 1 at once when FILE cannot be read, instead of waiting forever.

### Changed
- Layers made explicit. The Swift package is split into `GobiModel` (pure logic, no imports), `GobiClient` (gobid connection), `GobiEditor` (AppKit editor) and `GobiApp`; `scripts/check-layers.sh` enforces the imports. The Go core is ordered as foundation, services, transport, composition and entry point; `internal/layers` enforces the imports. See `docs/architect/layers.md` and the diagram `docs/diagram/gobi-layers.html`.
- The macOS UI moved from `ui-macos/` to `ui/macos/`, so `ui/windows/` and `ui/linux/` can sit beside it. Older entries below keep the old name.
- The handshake and the control channel are binary now (protobuf wire format, hand-coded in `internal/wire` and `GobiClient/Wire.swift`, no dependency). A JSON handshake is refused with a reply that says so. The LSP channel still carries JSON-RPC because gopls speaks it and the broker passes the bytes through. Both sides test the same golden bytes; the wire parser has a fuzz test. Field layout in `docs/architect/wire-protocol.md`.
- `gobid` with no arguments now serves instead of printing usage.
