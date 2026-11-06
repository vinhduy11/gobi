# Go toolchains: plan

Mocks: `Toolchains` (the window) and `ToolchainMenus` (Run > Go Toolchain submenu, the toolbar popup, the Install Version
sheet, the update notice and Run on Multiple Go Versions).

Model: a project has a **mode** (Auto from go.mod, Pinned to one version, Installed only) and, when pinned, a chosen version.
The choice resolves to a `GOROOT` (or none, meaning the `go` on PATH as today). Run, Test, Vet, Build, Debug, Profile and gopls
all start with that GOROOT: `<goroot>/bin/go` first on PATH, `GOROOT` set, `GOTOOLCHAIN=local` so the chosen version is
exactly what runs.

| Step | What | Where | Notes |
|---|---|---|---|
| 1 | Run with a chosen Go | core `runner` (`Request.GoRoot`), run channel field 7, Swift `RunWire`/`RunClient` | the folder must hold an executable `bin/go`; never taken from a project file |
| 2 | Choice model | Swift `ToolchainChoice` (pure): resolve mode + go.mod + installs to a GOROOT or a "missing" state; stored per project | tests first |
| 3 | Menus and popup | Run > Go Toolchain submenu, toolbar popup, Toolchains window radio and mode control | check mark = active version; Auto shows the go.mod line |
| 4 | Install and update | core `toolchain.InstallVersion` (`golang.org/dl` + `download`), `toolchain.Available` (go.dev release list), control `toolchain/install`, `toolchain/available`; Install Version sheet with progress; update notice | network and downloads only after the user presses Install |
| 5 | gopls with the chosen Go | `lsp` hello carries the GOROOT; the broker restarts with the new environment when it changes | existing editors reconnect |
| 6 | Run on multiple versions | Swift runs `go vet` and `go test ./...` once per checked version through the run channel, one at a time, and fills the table | uses step 1 |

Each step: a failing test first for pure logic, a commit, an entry in `ui-mock-gap.md` and the changelog.

## Status
Steps 1 to 4 are built (run with a chosen Go, the choice model, the menu and toolbar popup, install and update check).
The install and the release list are covered by tests with a fake `go` and a fake release server; a real download was not run
in this session. Steps 5 (gopls with the chosen Go) and 6 (run on multiple versions) are built and covered by `--selftest-toolchain`
(run it with `--newer FOLDER`, a module whose go.mod needs a Go newer than the second-newest installed one). The last multi-version result is kept per project (pure model `MultiVersionSnapshot`, preferences key `gobi.multiversion.<project>`), shown on reopen with a "last run" line, and cleared with the Clear button. Self-test: `GobiApp FOLDER --selftest-toolchain`
(needs two installed Go versions and a main.go that prints `runtime.Version()`).
