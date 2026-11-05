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
`ui-macos/` (AppKit, TextKit 2): the editor, gutter, colouring, explorer, tabs and dialogs. A Windows UI is a new
front end. The editor is the costly part: colouring, input methods such as Vietnamese, 100k-line files, keystroke time.

## Options for a Windows UI (not chosen yet)
1. Native: WinUI 3 with C#. Looks and feels like a Windows IDE; the editor has to be written again.
2. One shared web UI (Tauri or Electron with Monaco or CodeMirror) for Windows and Linux, Swift kept on macOS. Cheapest,
   but it is the re-skinned web IDE the project set out to avoid.
3. macOS only until the core is stable, then choose. This is the current plan.

## Habits that keep the choice open
- Put new platform-specific code in core behind a small interface with one file per platform (transport, pty), so adding
  Windows means adding a file.
- Put logic in the core or in pure Swift modules, and keep AppKit code to drawing and input.

Revisit when the core has the debug, profiler and terminal channels, which is when the cost of a second UI can be sized.
