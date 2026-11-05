# UI against the mockups

Rule: the UI follows the mockups (`docs/claude/rule.md`). This lists where the macOS app differs today. Mock names are
the boards on the canvas; copies are in `docs/artifact/2026-11-05-ui-mockup/`. Update the status column as gaps close.

| Screen (mock) | In the mock | In the app today | Status |
|---|---|---|---|
| Welcome | Left: icon, version and "Go ready", four action rows with a subtitle and shortcut, drag-a-folder zone. Right: search box, recent rows with badge (go.mod, go.work · n modules), branch, Restricted and no-git chips. Footer: "Show this window when Gobi launches", "Clear recent…" | Icon, title, four buttons, plain list of recents | open |
| New Project | Template list in two groups (Go module: command-line tool, library, HTTP service, gRPC service, workspace; Other: empty module, custom templates) with a description; name, location, module path, Go version "Auto · installed", environment; options (git init on master, .gitignore/.env.example/README, sample test, add to an existing go.work); "Will create" file preview; Cancel and Create | Alert-style form: template popup, name, location, module path, Go version, git checkbox | open |
| Workspace trust | App icon, question, two bullet lists (what stays, what turns off), "Also trust projects in ~/Work", three buttons | Standard alert with a sentence and the parent-folder checkbox | open |
| Edit (main window) | Toolbar: Run, Debug, Profile, run target, environment and Go version pop-ups, gopls status, search (⌘⇧P). Sidebar with Files, Symbols and Tests; git status marks (M, A); source control block with Commit…. Editor tabs, breadcrumb, code lens (references, implementations, run test). Inspector with outline, Go module and this-file settings. Bottom panel tabs: Problems, Tests, Terminal, Debug, Profiler, Git, Output. Status bar: branch, gopls state, line and column, encoding, line ending, Go version, format on save | Explorer, editor tabs, plain-text problems, one status line | open |
| Menu bar | Gobi, File, Edit, View, Go, Run, Debug, Window, Help with the listed items and shortcuts | App, File (New Project, Open, Open Recent, Clone, Import, Save, Close Tab, tabs), Edit (standard, Find) | open |
| Find in file | Find bar with previous and next, Done | Built as the mock | done |
| Read-only notice | Banner for files with a very long line | Status line text only | open |
| Clone, Import dialogs | Form dialogs as in the mock | Alert-style forms | partly |
| Settings (Editor, Languages), JSON, Markdown preview, Environments, Go toolchains, Debug, Profile | Full screens | Not built (later slices) | later |
| Terminal | Only a "Terminal" tab label in the bottom panel; no screen | Not built | mock first |

Order suggested: Welcome, New Project and Trust first (small, already exist), then the main window shell (toolbar,
sidebar tabs, bottom panel, status bar), then menus. The terminal gets its mock before its code.
