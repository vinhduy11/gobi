# UI against the mockups

Rule: the UI follows the mockups (`docs/claude/rule.md`). This lists where the macOS app differs today. Mock names are
the boards on the canvas; copies are in `docs/artifact/2026-11-05-ui-mockup/`. Update the status column as gaps close.

| Screen (mock) | In the mock | In the app today | Status |
|---|---|---|---|
| Welcome | Left: icon, version and "Go ready", four action rows with a subtitle and shortcut, drag-a-folder zone. Right: search box, recent rows with badge (go.mod, go.work · n modules), branch, Restricted and no-git chips. Footer: "Show this window when Gobi launches", "Clear recent…" | Built as the mock | done |
| New Project | Template list in two groups (Go module: command-line tool, library, HTTP service, gRPC service, workspace; Other: empty module, custom templates) with a description; name, location, module path, Go version "Auto · installed", environment; options (git init on master, .gitignore/.env.example/README, sample test, add to an existing go.work); "Will create" file preview; Cancel and Create | Built as the mock. Still different: gRPC and custom templates are listed but unavailable; Environment is fixed to local until environment profiles exist; the preview does not list `.gobi/environments.toml` yet | done, with gaps |
| Workspace trust | App icon, question, two bullet lists (what stays, what turns off), "Also trust projects in ~/Work", three buttons | Built as the mock | done |
| Edit (main window) | Toolbar: Run, Debug, Profile, run target, environment and Go version pop-ups, gopls status, search (⌘⇧P). Sidebar with Files, Symbols and Tests; git status marks (M, A); source control block with Commit…. Editor tabs, breadcrumb, code lens (references, implementations, run test). Inspector with outline, Go module and this-file settings. Bottom panel tabs: Problems, Tests, Terminal, Debug, Profiler, Git, Output. Status bar: branch, gopls state, line and column, encoding, line ending, Go version, format on save | Done: editor tabs, breadcrumb, bottom panel with seven tabs and a working Problems list, status bar (branch, gopls, caret, encoding, line ending, Go version). Open: toolbar, sidebar tabs (Symbols, Tests), git marks and source control block, inspector, "gofmt on save" in the status bar | partly |
| Menu bar | Gobi, File, Edit, View, Go, Build, Run, Git, Window, Help with the listed items and shortcuts (Menus mock, Debug merged into Run, Git submenus) | Every menu and item of the mock, in its order; items with a feature are live, the rest are disabled (Check for Updates, New File, Paste from History, Copy Reference, Column Selection Mode, Macros, Bookmarks, AutoFill, Tool Windows, Appearance, Quick Definition and the other Quick/Recent items, Compare with Clipboard, Zoom, Notifications, Back/Forward, Next/Previous Problem, Go to Test, Build Artifacts, Run with Coverage, the run-configuration items, Pause, Force/Smart steps, Run to Cursor, Reset Frame, the method/field/temporary breakpoints, Show History, Annotate, Merge All Project Windows, Move Tab to New Window, Next/Previous Project Tab, Search, Gobi Help, Release Notes, Report an Issue). Shortcuts that Gobi already used keep their item (Debug F5, Stop ⇧F5, Resume F5, Step Over F10, Step Into F11, Step Out ⇧F11, Toggle Line Breakpoint ⌘\\); Push and Recent Files show none, Run Anything none (a double ⌃ is not a key); see menu-shortcuts.md. Debugging Actions holds Restart. The dialogs for Tag, Reset HEAD, Stash, Rebase, Remotes and Worktrees are plain alert sheets with no mock yet. | done, items wait for features |
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
| Context menus (editor, explorer, tab) | Mock added; built. Explorer > New (File, Folder, Go File, Go Test File) is live, and a right click on empty space gives the project folder's menu. Disabled until their features exist: Go to Implementation, Find References, Rename, Code Actions, Cut/Copy/Paste of files, Find and Replace in Files, Refactor, Organize Imports, Delete, Build Module |
| Explorer file icons and colours | Icons by file type in the reference style done (grey folders, GO badge, outlined pages with a letter, bare glyphs). Name colours for git status and ignored files are done |
| Code help | Done: Go to Definition, Find References, Rename, Organize Imports, Code Actions, Format Document, completion popup, hover. Go to Implementation (⌘F12) is built. Signature help (popup above the caret on `(` and `,`, Esc or `)` closes, Edit > Parameter Info ⇧⌘Space) and snippets in completion (tab stops with Tab) are built; the mock has the popup and the menu item. The code lens is built (section "Code lens"); gopls sends placeholders only when `usePlaceholders` is set, so parameters are not filled in by default |

## Run and test
| Screen (mock) | Status |
|---|---|
| Tests panel | Built to the new mock: counts, time, tree with failure messages, Run Failed, Run All, filter box (case-insensitive substring of test or package name; Esc clears). Failing line: picking a failed test or its message opens the file at that line |
| Output panel | Built to the new mock: command, state, time, streamed text, Stop, Clear. `file.go:12:5` mentions are links that open the file at that line |
| Menu: Run, Run Tests, Run Test at Cursor | Live, with Run on Multiple Go Versions. Profile, Edit Run Configurations, Environment and Go Toolchain submenus still wait for toolchains and environments |
| Toolbar Run button and run target | Built (Run turns into Stop while running). Debug, Profile, environment and Go version popups are drawn disabled until those features exist |
| Gutter and code lens "run test" | A green Run button in the gutter on each test, benchmark and fuzz function of a _test.go file runs just that test. The code lens is in section "Code lens" |

## Code lens
| Screen (mock) | Status |
|---|---|
| Code lens | Grey "N references · M implementations" and "run test" on each top-level func, method, type and interface method. The mock now draws it at the END of the declaration line (it showed a line of its own above). Built as an end-of-line annotation, in the same place as the debugger's inline values. A separate line above the declaration needs extra height in the layout; a custom NSTextLayoutFragment was judged not workable (TextKit places the caret and mouse hits by line fragment bounds, so selection, hit testing and the gutter alignment would break) and was not built. Counts come from gopls references (minus the declaration) and implementation, only for declarations within 40 lines of the screen, after typing or scrolling pauses (0.5 s, 0.15 s), cached per declaration and document version, at most 200 a file; hidden while text changed and the new counts are not in. A click runs Find References, Go to Implementation or the test. Settings > Editor > Show code lens (default on). Not built: "debug test" (no debug-a-test flow yet), gopls' own codeLens answers |

## Code lens
| Screen (mock) | Status |
|---|---|
| Code lens | Grey "N references · M implementations" and "run test" on each top-level func, method, type and interface method. The mock now draws it at the END of the declaration line (it showed a line of its own above). Built as an end-of-line annotation, in the same place as the debugger's inline values. A separate line above the declaration needs extra height in the layout; a custom NSTextLayoutFragment was judged not workable (TextKit places the caret and mouse hits by line fragment bounds, so selection, hit testing and the gutter alignment would break) and was not built. Counts come from gopls references (minus the declaration) and implementation, only for declarations within 40 lines of the screen, after typing or scrolling pauses (0.5 s, 0.15 s), cached per declaration and document version, at most 200 a file; hidden while text changed and the new counts are not in. A click runs Find References, Go to Implementation or the test. Settings > Editor > Show code lens (default on). Not built: "debug test" (no debug-a-test flow yet), gopls' own codeLens answers |

## Main window shell
| Screen (mock) | Status |
|---|---|
| Sidebar tabs Files / Symbols / Tests | Built; Symbols comes from gopls, Tests mirrors the Tests panel |
| Inspector: Outline, Go module, This file | Built. Format on save works (Go files, through gopls); the organize-imports-on-save switch is stored but not acted on yet |
| Explorer name colours, branch, gutter marks, Source control block, Git tab (Changes, Log, diff), stage and unstage, commit, branch list, switch and create | Built. Push, Pull (fast-forward only) and Discard Changes (row menu, asks first) are built. Merge into Current Branch… (branch menu, confirmation; a conflict is aborted and reported) is built, and so is auto-fetch (Settings > Git). Not built: resolving conflicts in the editor, blame, a side-by-side diff |

## Settings
| Screen (mock) | Status |
|---|---|
| Settings > Editor | All controls are live (plan and risks: `docs/implement/editor-settings.md`). Wrap on very large files is not measured yet |
| Settings > Languages | Go entry with its format-on-save switch only. JSON and Markdown wait for their language services |
| General, Keymap, Terminal, Git, Advanced tabs | Built; every control is live except "Check for updates automatically" (no update server). Differences from the mocks: Terminal "Start in" offers Project folder / Home folder (the mock said Last used), and Advanced "Large files" is a line length, not a size. The Large files limit and the gopls path apply to open files at once (read-only re-evaluated, Go panes reconnect); terminal settings apply to new terminals only. See `docs/implement/settings-tabs.md` |
| Setup window (missing tools) | Built to the new Setup mock |

## Toolchains and environments
| Screen (mock) | Status |
|---|---|
| Go toolchains window | List, go.mod note, mode control, pinning, Install version sheet and Check for updates are built. Run on multiple versions and gopls with the chosen Go are built too. The Install version sheet is a real sheet on the Toolchains window (Cancel and Done). Run on multiple versions keeps the last result per project, shows "last run" and has Clear. Nothing left unbuilt in this row |
| Toolbar Go version popup, Run menu Go Toolchain submenu | Built |
| Environments window (profiles, variables, Keychain secrets, `.gobi/environments.toml`), toolbar popup, resolved targets, ask before non-local runs | Built. The "Block DROP / CREATE" switch is stored and shown in the confirmation but nothing intercepts SQL; Debug passes the environment to dlv; remote profile kinds beyond a flag are not modelled |

## Debug
| Screen (mock) | Status |
|---|---|
| Debug toolbar state, Debug panel, gutter breakpoints, paused line | Built: Continue, Over, Into, Out, Restart, Stop, call stack, variables of the selected frame, status in the status bar |
| Debug navigator on the left, Watch, inline values, conditional breakpoints, attach, expandable variables | Built |

## Profiler
| Screen (mock) | Status |
|---|---|
| Profiles list, Flame, Top, sample type, inspector, capture from a live program, open a file | Built (a bottom-panel tab, not a full window). Filter box, Source view (per-line cost for the selected function only, "Show whole file" toggle, double click opens the file), Compare two profiles, Capture menu with CPU, Heap, Allocations, Goroutines, Mutex and Blocking. Not built: `go test -cpuprofile` button in the Tests panel; the mutex and block presets return empty profiles unless the program sets the profile fraction |

## Terminal
| Screen (mock) | Status |
|---|---|
| New terminal menu: split, kill, clear, find, shells, settings | Built. Find counts matches and scrolls to them but does not highlight them (the terminal library has no public selection call); Terminal settings opens Settings, whose Terminal tab is still disabled |
| Restricted Mode notice: Learn More | Built as an explanatory dialog |

## Find in Files
| Screen (mock) | Status |
|---|---|
| Find tab: query, options, filter, grouped results, replacement, Replace All, Replace in File | Built as an eighth bottom-panel tab. Also built: Replace on a single match, a per-file checkbox that leaves a file out of Replace All, and the last 10 searches in the query field's dropdown (`gobi.findHistory`). Not built: searching only open files |

## JSON and Markdown
| Screen (mock) | Status |
|---|---|
| JSON editing: language chip, error mark in the Explorer, problem entry, outline of keys, inspector facts, Format on save | Built, except the chip in the toolbar (the status bar carries the same text) and the key icons in the outline |
| Markdown preview: Source / Split / Preview, outline of headings, inspector facts, safe preview note | Built. The preview does not scroll with the editor yet |

## Session restore and changes on disk

Done: the project window saves its tabs, carets and layout on close and quit and restores them on open; a one-second poll plus window focus detects files changed, deleted or created by something else (notice bar above the editor, explorer refresh). Mock: `ExternalChange`. Also done: changes are noticed through FSEvents on the project folder (about 150 ms coalescing) with a 10 s safety poll, and unsaved edits are kept aside on window close and quit (Application Support/Gobi/Recovery, one file per project and file) and restored as edited with a Keep / Discard notice (Keep Mine / Reload from Disk when the file changed since). Decision logic: `Recovery` in GobiModel. Also done: edited buffers are written every 20 s too (changed ones only; ProjectWindowController.recoveryInterval, shortened by --selftest-session). Not done: the close dialog still asks Save / Don't Save, and Don't Save discards the kept buffer; files opened from outside the project folder rely on the 10 s poll.
