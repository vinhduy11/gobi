# Windows and Linux: how Gobi stays portable

Decision: build macOS first, keep the core portable, and decide the Windows UI later. Two cheap habits now keep that
choice open.

## What carries over
- `core/` (gobid, Go): the gopls broker, language services, project requests, handshake and control messages, and later
  debug, profiler, git and terminal. Nothing in it depends on macOS except two small pieces:
  - the unix-domain socket and its peer check (`internal/ipc`): Windows needs a named pipe with an owner check;
  - the pty channel: Windows needs ConPTY.
- The wire format (`docs/architect/wire-protocol.md`) is plain protobuf wire encoding. A Windows UI needs its own small
  encoder and decoder, nothing else.
- The pure Swift logic (line index, tokenizer, tab strip, project and form checks) has no AppKit or Foundation in it.
  It can be ported by hand to another language; it cannot be linked from one.

## What does not carry over
`ui/macos/` (AppKit, TextKit 2): the editor, gutter, colouring, explorer, tabs and dialogs. A Windows UI is a new
front end. The editor is the costly part: colouring, input methods such as Vietnamese, 100k-line files, keystroke time.

## Order of decisions
1. **Windows first.** Decide the Windows UI by benchmark (below), then build it.
2. **Linux later.** Research only for now; no work starts until Windows is settled.
The decision is made by measurement, not by preference: build a minimal editor in each candidate and run the numbers.

## Benchmark for a candidate UI (Windows now, Linux when it starts)
Same fixtures and limits as `gobi-bench` on macOS: open a 100k-line Go file in 300 ms or less; a keystroke in 16 ms or
less; a file with one 1 MB line stays usable (or opens read-only with a notice); Vietnamese typing (Telex/VNI through the
platform input method) gives correct text; memory and start-up time of the empty window and of a project with ~770 files
(OpenIDEA publishes 0.9 s to a window, 1.1 s to ready, 169 MB; use as a target, they are self-reported). Record
the machine, build type and the median of five runs.

## Candidates
| Platform | Candidate | Why it is on the list | Open risk |
|---|---|---|---|
| Windows | WinUI 3 (C++ or C#) with an editor drawn on DirectWrite | most native; precedent: Gridex (C++/WinUI 3) | no code-editor widget, so the editor is built by us |
| Windows | WinUI 3 hosting Scintilla (Win32 control) | native control with a mature editor engine | embedding into WinUI, gutter and inline annotations |
| Windows | Swift + WinUI 3 (`swift-winrt`) | would reuse `GobiModel` and `GobiClient` as they are; precedent: Arc on Windows | bindings are incomplete; sources seen are from 2023-2024 |
| Windows | GPU-drawn UI (Zed GPUI, Lapce Floem) | best raw speed; Zed uses DirectX 11 on Windows | not native widgets; against the "as native as possible" goal; fallback only |
| Linux | GTK4 + GtkSourceView 5 | editor widget exists; GNOME Builder precedent; Ghostty uses GTK4 | GtkTextView with huge files and very long lines |
| Linux | Qt 6 (C++) | Gridex uses it; strong with KDE | no ready source-view widget; C++ only |

## What other projects do (checked from READMEs and search results, not from their source)
- **Ghostty**: a shared core (Zig, `libghostty`) with a native GUI per platform: Swift (AppKit and SwiftUI) on macOS, GTK4 on
  Linux. Same shape as Gobi (core daemon + thin native UI). A Windows GUI was not found.
- **Gridex** (database IDE, Apache 2.0): three separate native apps, AppKit (Swift) on macOS, WinUI 3 (C++) on Windows,
  Qt 6 (C++20) on Linux; no web view. No shared core between the apps: only a common adapter contract of about 50
  methods. Result: features drift (7 drivers on macOS, 6 on Windows and Linux; ClickHouse macOS only). This is the
  drift that the parity guide in `docs/claude/rule.md` is meant to prevent.
- **Zed** (GPUI, Rust): GPU-drawn UI on macOS (Metal), Linux (Vulkan) and Windows (DirectX 11). Windows described as stable in
  late 2025 by non-official sources; check zed.dev before relying on it.
- **Lapce** (Floem + wgpu, Rust): GPU-drawn on all three desktops.
- **GNOME Builder**: GTK4 with GtkSourceView 5 (which extends `GtkTextView`).
- **OpenIDEA** (IntelliJ-style IDE, Rust core, Apache 2.0, early alpha): the README says "a native app with a Rust core" and does
  not name the UI technology. The repo has `src-tauri`, `vite.config.ts` and a `tauri` topic, so a Tauri webview UI is likely
  (inference, unconfirmed). Plugins are sandboxed WebAssembly components (API still a preview). It publishes benchmarks
  against IntelliJ IDEA on Windows 11 (the figures above); the README itself says the "ready" states are not equal work.
- Not checked: Notepad++ (Scintilla) and Kate (KTextEditor); the notes about them are general knowledge.

## Linux: GTK4 or Qt 6 (research later, notes kept)
| | GTK4 (+ libadwaita) | Qt 6 |
|---|---|---|
| Editor widget | GtkSourceView 5 ready-made | `QPlainTextEdit`, QScintilla, KTextEditor or custom |
| Desktop fit | native on GNOME (Ubuntu, Fedora default); foreign on KDE | native on KDE; acceptable on GNOME |
| Huge files, 1 MB line | main risk (GtkTextView) | a custom view gives control, at a cost |
| UI language | C, Rust (gtk4-rs), Vala, Python, Go (`gotk4`) | C++; Rust bindings less mature |
| Licence | LGPL | LGPL; watch dynamic linking and commercial-only modules |
Leaning (to be tested, not decided): GTK4 + GtkSourceView unless the benchmark above fails; Qt 6 if it fails or KDE users matter.

## Habits that keep the choice open
- Put new platform-specific code in core behind a small interface with one file per platform (transport, pty), so adding
  Windows means adding a file.
- Put logic in the core or in pure Swift modules, and keep AppKit code to drawing and input.

Revisit when the core has the debug, profiler and terminal channels, which is when the cost of a second UI can be sized.

## Platform differences register
One row per difference found; owner says where the rule lives. Add a row when you meet a new one (`docs/claude/rule.md`).

| Area | macOS today | Linux / Windows | Owner |
|---|---|---|---|
| File names | any valid name | Windows rejects reserved names (`CON`, `NUL`…), trailing dot or space, long paths; reject on every target | core |
| Case | APFS default case-insensitive | Linux case-sensitive | core |
| Line endings | LF, CRLF, lone CR handled in line index | same input, same positions | shared module |
| IPC | unix socket + peer check | named pipe + owner check (Windows) | core |
| Terminal | pty, login shell | ConPTY (Windows), `$SHELL` | core |
| File watching | FSEvents | inotify, ReadDirectoryChangesW; coalescing differs | core |
| Tool discovery | PATH extended for Finder launches | `.exe`, GUI-session PATH | core |
| Logs, preferences | `~/Library/Logs/Gobi`, UserDefaults | XDG dirs, `%AppData%` | UI |
| Shortcuts | ⌘ ⌥ ⌃ | Ctrl, Alt; desktop-reserved keys | shared spec |
| Fonts | SF Mono, Nerd Font fallback | Cascadia, DejaVu Sans Mono | UI |
| Signing, updates | ad hoc now; Developer ID + notarization later | package signing | release |
