# UI against the mockups

Rule: the UI follows the mockups (`docs/claude/rule.md`). This lists where the macOS app differs today. Mock names are
the boards on the canvas; copies are in `docs/artifact/2026-11-05-ui-mockup/`. Update the status column as gaps close.

| Screen (mock) | In the mock | In the app today | Status |
|---|---|---|---|
| Welcome | Left: icon, version and "Go ready", four action rows with a subtitle and shortcut, drag-a-folder zone. Right: search box, recent rows with badge (go.mod, go.work · n modules), branch, Restricted and no-git chips. Footer: "Show this window when Gobi launches", "Clear recent…" | Built as the mock | done |
| New Project | Template list in two groups (Go module: command-line tool, library, HTTP service, gRPC service, workspace; Other: empty module, custom templates) with a description; name, location, module path, Go version "Auto · installed", environment; options (git init on master, .gitignore/.env.example/README, sample test, add to an existing go.work); "Will create" file preview; Cancel and Create | Built as the mock. Still different: gRPC and custom templates are listed but unavailable; Environment is fixed to local until environment profiles exist; the preview does not list `.gobi/environments.toml` yet | done, with gaps |
| Workspace trust | App icon, question, two bullet lists (what stays, what turns off), "Also trust projects in ~/Work", three buttons | Built as the mock | done |
| Edit (main window) | Toolbar: Run, Debug, Profile, run target, environment and Go version pop-ups, gopls status, search (⌘⇧P). Sidebar with Files, Symbols and Tests; git status marks (M, A); source control block with Commit…. Editor tabs, breadcrumb, code lens (references, implementations, run test). Inspector with outline, Go module and this-file settings. Bottom panel tabs: Problems, Tests, Terminal, Debug, Profiler, Git, Output. Status bar: branch, gopls state, line and column, encoding, line ending, Go version, format on save | Done: editor tabs, breadcrumb, bottom panel with seven tabs and a working Problems list, status bar (branch, gopls, caret, encoding, line ending, Go version). Open: toolbar, sidebar tabs (Symbols, Tests), git marks and source control block, code lens, inspector, "gofmt on save" in the status bar | partly |
| Menu bar | Gobi, File, Edit, View, Go, Run, Debug, Window, Help with the listed items and shortcuts | All menus and items of the mock; the ones without a feature behind them are disabled until it exists (Settings, New File, Format, Rename, Go to…, Run, Debug and others) | done, items wait for features |
| Find in file | Find bar with previous and next, Done | Built as the mock | done |
| Read-only notice | Banner for files with a very long line | Status line text only | open |
| Clone, Import dialogs | Form dialogs as in the mock | Alert-style forms | partly |
| Settings (Editor, Languages), JSON, Markdown preview, Environments, Go toolchains, Debug, Profile | Full screens | Not built (later slices) | later |
| Terminal | Mock added: terminal tabs in the bottom panel, new, split, kill, Restricted state, Terminal menu | Core `pty` channel and the Swift `TerminalClient` are built and checked; the Terminal tab is built to the mock (tabs, new, kill, clear, Restricted notice). Not built: split, choosing another shell, the ⌃⇧` shortcut, a Learn More button | done, with gaps |
| Code help (completion popup, hover, go to definition, references, rename F2, code actions ⌘., format, organize imports) | Completion popup, code lens and menu items in the Edit mock; Settings > Languages | None of these in the app. gopls answers them through the lsp channel (`gobi-probe --hover --format`), the UI does not ask yet | open |

Order suggested: Welcome, New Project and Trust first (small, already exist), then the main window shell (toolbar,
sidebar tabs, bottom panel, status bar), then menus. The terminal gets its mock before its code.

## Added after the first audit
| Screen (mock) | Status |
|---|---|
| Context menus (editor, explorer, tab) | Mock added; built. Disabled until their features exist: Go to Implementation, Find References, Rename, Code Actions, New, Cut/Copy/Paste of files, Find and Replace in Files, Refactor, Organize Imports, Delete, Build Module |
| Explorer file icons and colours | Icons by file type in the reference style done (grey folders, GO badge, outlined pages with a letter, bare glyphs). Not done: name colours for git status and ignored files (needs the git service) |
| Code help | Go to Definition and Format Document done. Completion popup and hover are read from gopls but not shown yet; rename and code actions not started |
