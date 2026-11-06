# Settings tabs: plan

Mocks: `SettingsEditor`, `SettingsLanguages` (built in part), `SettingsGeneral`, `SettingsKeymap`, `SettingsTerminal`,
`SettingsGit`, `SettingsAdvanced`, and `Setup` (missing tools) on the mockup canvas. Until a tab's feature exists its
controls stay drawn disabled in the app (rule: the UI follows the mocks, controls without a feature are disabled).

Order of work, each step test first, one commit each:

| # | Tab | What becomes live | Needs |
|---|---|---|---|
| 1 | Advanced | Check Setup button (done: Setup window), Run `.env` switch (done), Reset All Settings, Large files, daemon status and Restart, log level | A `daemon/status` control call; log file path |
| 2 | General | On launch (reopen last project or Welcome), recent projects count, Forget Recent Projects, trusted folders list with Remove, update check switch | ProjectStore settings; trust store listing; update check waits for a release feed |
| 3 | Terminal | Shell choice, start folder, font and size, cursor style, scrollback, Option as Meta, copy on select, bell | SwiftTerm options; shell list from `/etc/shells`; per-terminal restart |
| 4 | Git | Git path, explorer colours switch, gutter marks switch, refresh on focus switch, commit message limits | Gutter marks and the commit UI (git slice 2); the switches for what already exists can ship first |
| 5 | Keymap | Search, per-command shortcut editing, conflict warning, Reset to Default, keymap presets | `ShortcutList` made editable, stored overrides applied to the menu bar and the Command Palette |
| 6 | Editor (rest) | Font, line height, indent, tab width, line numbers, invisibles, wrap, ruler, auto save | Editor font/line-number/wrap options in `EditorView` (today fixed) |

Each tab ships as: a pure model for its stored values (in `GobiModel`, with tests), the pane in
`SettingsWindowController`, and a line in the self-test that changes the value and checks the effect.

Also in this round (added to the mocks): the Setup window (`Check Setup…` in Help; opens by itself at launch when go or gopls
is missing; Install runs `go install` for gopls and dlv only after the user presses it), and the Run row in Settings > Editor
for loading `.env`.

## Status
All five tabs are built (General, Keymap, Terminal, Git, Advanced) with the Editor tab from before; `GobiApp FOLDER --selftest-settings`
checks them (the folder is a git repository with an edited file). Built since: quit confirmation (General), terminal start
folder, scrollback and copy-on-select (Terminal), git program path and fetch interval (Git), gopls path and the large-file limit
(Advanced). The two paths travel in the handshake `tool` field (git channel: git; lsp channel: gopls for Go); gobid refuses a
relative or non-executable path. The git path is process-wide in gobid (the last git session to connect sets it). Still drawn
disabled: "Check for updates automatically" (no update server exists).

Limits of the terminal library (SwiftTerm 1.5.1): scrollback is fixed when a terminal view is made, so a changed value applies to
new terminals only (an open one keeps its buffer); the start folder and the shell also apply to new terminals. Copy on select uses
the open `selectionChanged` callback of `TerminalView`; the self-test checks that the callback fires and the pasteboard write, but
a select-all returns empty text in the offscreen test terminal, so a real drag selection is not driven by the test.
"Large files" is the existing read-only-by-line-length rule (the mock's "Over 5 MB" was changed to a line length; the real rule
never looked at file size). A changed large-file limit is applied to open files at once (a file past the new limit turns read-only with the status notice, one under it is editable again), and a changed gopls path reconnects the open Go files through `EditorPane.reconnect()`, so gobid serves them with the new program (its broker keys servers by tool path). Only the terminal settings stay "new terminals only".
