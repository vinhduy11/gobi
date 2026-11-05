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

- `project/new` options: sample test, scaffold (README, .gitignore, .env.example), add to an existing go.work; `project/preview` lists the files `project/new` would write (shared plan, tested to match the disk). The CLI and HTTP templates now have testable code.
- `ui/macos/`: the Welcome window follows its mock: sidebar with icon, version and Go status, four action rows with subtitle and shortcut, drop zone for a folder; recent projects with search, go.mod and go.work · n modules badges, Restricted chip and git branch; "Show this window when Gobi launches" (off by default, so the newest project reopens) and "Clear recent…". `GobiApp --selftest-welcome` checks and paints it.

- Mockups: terminal panel (terminal tabs, new, split, kill, shell menu, Terminal menu items) and the Restricted Mode state for it, on the canvas and in `docs/artifact/`.

- `ui/macos/`: New Project window follows its mock: grouped template list with descriptions (gRPC and custom templates are shown but unavailable for now), name, location, module path, Go version, environment (local only until environments exist), the four options and a "Will create" list that gobid computes (`project/preview`). `GobiApp --selftest-newproject` checks it against gobid and paints it.

- `ui/macos/`: the workspace trust question is its own window as in the mock (icon, explanation, what Restricted Mode keeps and turns off, "Also trust projects in ~/…", Cancel, Open in Restricted Mode, Trust and Open). `GobiApp --selftest-trust` checks and paints it.

- `ui/macos/`: the project window gets the mock's regions: breadcrumb under the tabs, a bottom panel with the seven tabs (Problems works, with severity icons, `file:line · source`, click to jump; the others say what comes later; View > Toggle Bottom Panel will use `toggleBottomPanel`), and a status bar with the git branch, gopls state, caret, encoding, line ending and Go version. A file now opens with the caret at its top.

- `internal/pty` and the `pty` channel: a login shell on a pseudo-terminal per connection, started in the project folder, with resize and exit code; refused for a workspace that is not trusted.

- `ui/macos/`: the menu bar follows the Menus mock: Gobi, File, Edit, View, Go, Run, Debug, Window, Help with the mock's items and shortcuts, built from `MenuSpec` (tested against a transcription of the mock). Items whose feature is not built yet are shown disabled. New commands: Close Project, Save All, Reveal in Finder, Toggle Sidebar, Toggle Bottom Panel, Enter Full Screen, Minimize, Zoom, Bring All to Front. `gobi-check terminal DIR` checks the terminal client against gobid.

- `ui/macos/`: the Terminal tab of the bottom panel: one shell per tab on gobid's `pty` channel, new, kill, clear and shell menu, a Restricted Mode notice with "Trust Project…" (which reopens the project trusted). Drawn by SwiftTerm 1.5.1 (MIT), the only third-party package, imported by the app shell only. `GobiApp FOLDER --selftest-terminal` checks it end to end.

- `ui/macos/`: right-click menus for the editor, the explorer and the tabs, from the new Context menus mock and the GoLand project-view menu as reference. Live now: Go to Definition, Format Document, Cut, Copy, Paste, Select All, Copy Path (absolute, from project root, file name), Reveal in Finder, Jump to Source (F4 too), Close, Close Others, Close Tabs to the Right, and Go Mod Tidy and Download Go Modules (run in the Terminal, in the go.mod's folder, trusted projects only). The rest are shown disabled until their features exist.
- `ui/macos/`: Go to Definition (F12) and Format Document (⌥⇧F) through gopls, from the menu bar and the right-click menu; the format is one undo step and is dropped if the text changed meanwhile. `LSPResults` reads definition, completion, formatting and hover answers; completion and hover are read but not shown yet.
- `ui/macos/`: Help > Keyboard Shortcuts lists every shortcut from the same data the menus use; `Shortcut` reads the mock's notation; the self-test checks that every live menu item carries its key.
- `ui/macos/`: explorer file icons by type (GO, test, go.mod, go.sum, go.work, Markdown, YAML, JSON, TOML, Makefile, .gitignore, .env, shell, Dockerfile, proto, SQL, images) as coloured badges and symbols.

- `ui/macos/`: the terminal and explorer follow the new reference images. Terminal tabs are pills with an accent outline and a close mark, with the new and menu buttons right beside them (split and kill live in the menu); the terminal takes a slate background and a softer ANSI palette (`TerminalPalette`, with a light version, switching with the appearance). Explorer icons: grey outline folders, a solid cyan GO badge, outlined pages with a small letter for go.mod, .env, YAML and similar, bare glyphs for JSON and Markdown, in softer colours. The Terminal and Context menus mocks were updated first.

### Fixed
- `ui/macos/`: the bottom panel tabs and the terminal strip are easier to tell apart: tabs have room around their names, the current one has an accent underline and bolder text, the new-terminal and menu buttons are separate square buttons with a hover highlight and a divider before them. The self-test checks the spacing and that exactly one tab is current.
- `ui/macos/`: a menu item built with a method named `perform` crashed when chosen, because the name collides with `NSObject.perform(_:)`.
- `ui/macos/`: the project window no longer shrinks itself to the layout's fitting size (a holding priority above Auto Layout's window priority did it), and a saved window frame that is too small is ignored.
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
