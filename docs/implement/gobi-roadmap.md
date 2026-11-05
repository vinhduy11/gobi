# Gobi — Go IDE (macOS first), slice 1: repo + core daemon + gopls broker

## Context
New project in empty `vibe_coding/`. Goal: a Go IDE (GoLand / VS Code-Go class) that is a client of the
official Go toolchain only — gopls (LSP), dlv (DAP), go test/vet, pprof, gofmt/goimports, go.work.
Decided with user: **Go core daemon (cross-platform) + native Swift UI per OS** (macOS now, WinUI/GTK later),
talking over a local socket. Name: **Gobi** (`gobi` app, `gobid` core daemon).
Machine: Go 1.26.5, Swift 6.2 CLT (no full Xcode → SwiftPM only), gopls/dlv not installed.
Plan revised after a Codex review: gobid is an LSP **broker** (owns the gopls session), not a transparent pipe.

## Layout — `vibe_coding/gobi/`
```
gobi/
  CLAUDE.md                 lean index → docs/claude/{architect,rule,safety}.md
  README.md  CHANGELOG.md  .gitignore
  core/                     Go module `gobi/core` (stdlib + golang.org/x/sys for peer creds)
    cmd/gobid/main.go       daemon + `gobid doctor`
    internal/rpc/           LSP base-protocol framing, defensive (max Content-Length, header rules), fuzz test
    internal/ipc/           socket dir/lock/stale-probe/peer-UID check, handshake, channel routing
    internal/toolchain/     locate go/gopls/dlv, versions, pinned-version check (doctor)
    internal/lsp/           broker: one gopls per workspace, ID translation, cancel, server→client reqs, restart+replay
    internal/lsp/fakelsp/   controllable fake LSP server binary for deterministic tests
    internal/lsp/testdata/hello/   fixture module for the opt-in real-gopls test
  docs/{architect,implement,changelog,claude}/
```

## Key design (slice 1)
- **Channels = separate connections**, no multiplex envelope. Each new connection opens with a handshake
  `{protocol: 1, client_version, channel: "control"|"lsp"|"dap"|"pty", workspace_root}`; core replies
  accept/reject (version mismatch → reject). DAP and PTY channels reserved, not implemented in slice 1.
- **LSP broker**: one gopls per workspace root, shared by every UI window on that workspace. gobid is the LSP
  client: performs `initialize`/`initialized`, rewrites request IDs both directions (UI id ↔ gopls id table),
  forwards `$/cancelRequest` translated, answers `workspace/configuration` itself, forwards
  `applyEdit`/`showMessage`/`workDoneProgress`/`$/progress`/registerCapability to the UI. Message payloads are
  forwarded as JSON bytes; only `id`/`method` are peeked.
- **Restart**: on gopls exit → fail in-flight requests with a restart error, bump epoch, re-initialize, replay
  workspace folders + every open document's latest text/version (broker tracks didOpen/didChange/didClose),
  then notify UI `gobi/lspRestarted`.
- **Socket**: `$TMPDIR/gobi-<uid>/gobid.sock`; dir 0700 created with umask 077, lstat owner/type checks,
  socket 0600; path length checked against Darwin's limit with a short fallback; existing socket probed
  (dial) and removed only if stale; `flock` on `gobid.lock` for single instance; peer UID checked via
  `getsockopt LOCAL_PEERCRED`; SIGINT/SIGTERM → close clients, kill gopls, remove socket.
- **Logging**: `log/slog` JSON, fields component/session/epoch/method/id/duration; never logs source text.
- **Toolchain**: `doctor` reports only (never installs). Pinned versions recorded in README; install is an
  explicit setup step below. Multi-version selection and environment profiles are designed (section below) but
  not built in slice 1; keep `internal/toolchain.Find` taking a toolchain/env argument so they slot in later.

## UI design (target for slices 2–7; not built in slice 1)

**Guideline: Apple Human Interface Guidelines (macOS)**, built only from native AppKit components so the app looks
and behaves like Xcode/Finder rather than a re-skinned web IDE:
- Window: `NSSplitViewController` with sidebar (source list) / editor / inspector, unified toolbar, native tabs.
- Look: system colors + materials (vibrancy sidebar), automatic Light/Dark, accent color from System Settings,
  SF Symbols icons, SF Pro for UI, SF Mono for code/terminal. No custom theme engine in v1.
- Behaviour: standard menu bar (File/Edit/View/Go/Run/Debug/Window/Help), ⌘-based shortcuts per HIG,
  ⌘⇧P command palette, ⌘⇧O open symbol (gopls `workspace/symbol`), ⌘P quick open; full-screen and Stage Manager ok.
- Accessibility: VoiceOver labels come free with native controls; respect Reduce Motion / Increase Contrast;
  Vietnamese IME works because the editor is TextKit 2, not a custom text renderer.
- Information layout borrowed from GoLand/VS Code-Go (Go-specific panels: Problems, Tests, Debug, Profiler, Terminal, Git).

**Main window — editing**
```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   ▸ Run  ▣ Debug  ◷ Profile │ hello ▾ │ go1.26.5 · gopls ✓ · dlv ✓   ⌕ ⌘⇧P │
├───────────────┬──────────────────────────────────────────────────┬───────────────────┤
│ EXPLORER      │ main.go ×  server.go ×  server_test.go ×         │ OUTLINE           │
│ ▾ hello       │  12  func main() {                               │ ƒ main            │
│   ▾ cmd       │  13      srv := NewServer(":8080")               │ T Server          │
│     main.go   │  14      if err := srv.Run(); err != nil {       │   ƒ Run           │
│   ▾ internal  │  15 ▶        log.Fatal(err)          ← gutter:   │   ƒ Close         │
│     server.go │  16      }                         run/test/git  │                   │
│   go.mod      │  17  }                                           │ GO MODULE         │
│   go.work     │      ┌──────────────────────────────┐            │ hello             │
│               │      │ ƒ Run() error   (completion) │            │ go 1.26           │
│ GIT  main ↑1  │      │ ƒ Close() error              │            │ deps: 3           │
│ M server.go   │      └──────────────────────────────┘            │                   │
├───────────────┴──────────────────────────────────────────────────┴───────────────────┤
│ Problems 2 │ Tests │ Terminal │ Debug │ Profiler │ Git │ Output                       │
│ ⚠ server.go:42  unusedresult: result of fmt.Sprintf call not used   (go vet)          │
│ ✖ main.go:13    undefined: NewServr                                  (gopls)          │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ main.go  Ln 15, Col 9  ·  UTF-8  ·  LF  ·  Go  ·  gofmt on save  ·  ⎇ main            │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Debug mode (dlv via DAP)** — bottom panel switches to Debug, inspector becomes Variables/Watch:
```
│ ⏵ Continue ⤼ Over ⤓ Into ⤒ Out ■ Stop  │ goroutine 1 (main) ▾                          │
│ CALL STACK                │ VARIABLES                      │ WATCH                      │
│ ▸ main.(*Server).Run :42  │ ▾ s *Server                    │ len(s.conns)   = 3         │
│   main.main          :14  │     addr  = ":8080"            │ + add expression           │
│ GOROUTINES (12)           │   ▸ conns map[string]*Conn (3) │ BREAKPOINTS                │
│   ▸ 1 main  ▸ 7 net/http  │     err   = nil                │ ● server.go:42  if n > 10  │
```

**Profiler (pprof)** — CPU / heap / goroutine / block / mutex from `go test -cpuprofile` or a live `/debug/pprof`:
```
│ Source: cpu.pprof ▾  Type: CPU ▾  View: Flame | Top | Source   Filter: [ net/http   ]  │
│ ████████████████████████████████ main.main 100%                                      │
│ ██████████████████████ (*Server).Run 68%      ███████ runtime.gcBgMarkWorker 22%      │
│ ███████████ handle 34% ████████ json.Marshal 25%                                      │
│ TOP           flat    cum                                                             │
│ json.Marshal  18.2%   25.0%   → click opens source with per-line cost in the gutter   │
```

After approval, an interactive HTML mockup of these three screens can be published as an artifact
(saved to `docs/artifact/`) for review before slice 4.

## Environment profiles & Go toolchains (added after mockup review; core in slice 3, UI in slice 4)

**Environment profiles** (`local` / `dev` / `staging`, per workspace):
- Stored in `.gobi/environments.toml` (tracked, no secrets): env vars, ordered `.env` files, build tags, `GOFLAGS`,
  `GOOS/GOARCH`, working dir/args, optional toolchain override.
- Secrets live in macOS Keychain or a gitignored `.env`; never in the toml (matches the no-secrets-in-git rule).
- Toolbar popup selects the active profile; it applies to Run, Debug, Test, Profile; build tags + `GOFLAGS` are also
  passed to gopls so diagnostics match the selected env.
- **Targets are declared, not inferred**: a profile lists typed targets (`postgres`, `redis`, `kafka`, `opensearch`,
  `mqtt`) with the env var or file key that holds each host. The "Resolved targets" table shows only what is declared
  (value, config source, local?); any auto-discovery is advisory and labelled with its source.
- **Guarantee is limited to Gobi-owned actions** (run/test/debug/profile launches and Gobi tasks): a profile with a
  non-local target asks for confirmation first, and Gobi's own structured DB actions refuse DROP/CREATE-style
  commands there. Arbitrary Go code, shell commands and terminals cannot be policed; they only get the warning.
- **Precedence (low → high)**: inherited process env < ordered `.env` files < profile vars < Keychain values <
  per-launch overrides. Reserved Go variables (`GOTOOLCHAIN`, `GOFLAGS`, `GOWORK`, `GOOS`, `GOARCH`) are set from
  their own fields only. Secrets are redacted in logs, command previews, DAP variables, terminal capture, diagnostics
  and crash reports.
- **Terminal**: two modes, `clean` (default, no profile secrets) and `inherited` (explicit opt-in); never runs in an
  untrusted workspace; shell startup files run only in `inherited` mode.

**Go toolchains** (multiple versions):
- Official mechanisms only, kept separate: (a) Go's own toolchain switching (`go.mod` `go`/`toolchain` lines +
  `GOTOOLCHAIN` = `auto` | `local` | `<name>` | `<name>+auto` | `<name>+path`; no arbitrary filesystem path mode) and
  (b) side-installed SDKs via `golang.org/dl/goX.Y.Z` (wrapper must then run `goX.Y.Z download`).
  Project mode: Auto (go.mod) / Pinned / Installed only; each env profile may override.
- **Precedence** for the selected version (high → low): per-launch choice > env profile override > project mode >
  `go.work` > `go.mod` > user's `go env`. The resolved choice is shown in the toolbar popup.
- **Missing pinned toolchain** (offline, `GOTOOLCHAIN=local`, download failed): stable diagnostic with recovery
  choices (download, pick another, open Manage). Never silently fall back to a different Go version.
- Downloads: explicit user action only, honour `GOPROXY`/`GOSUMDB`, support cancel, report checksum failures.
- **gopls environment per workspace**: the selected `go` is first on PATH / via `GOTOOLCHAIN`; `GOWORK`, `GOFLAGS`,
  `GOOS/GOARCH`, tags, `GOMODCACHE`, `GOPATH`, `GOPROXY`, `GOSUMDB` computed explicitly; `GOROOT` is not forced.
- Core `internal/toolchain` lists installed SDKs, installs/updates on request (explicit user action only),
  picks the `go` binary per run, and restarts gopls with the selected toolchain (new epoch → existing restart+replay path).
- **Run on multiple versions**: run `go vet` + `go test ./...` on selected versions, show a per-version pass/fail/time table.
- Toolbar popup: Auto (go.mod) / installed versions / "Run on multiple versions…" / "Manage toolchains…".

## Steps
0. **DONE — UI mockup artifact** (Edit / Debug / Profile / Environments / Go toolchains, HIG look, Light/Dark tweak):
   published as a private Artifact. Copy to be saved to `gobi/docs/artifact/2026-11-05-ui-mockup.html` after the repo exists.
1. **Git**: `git init -b master` in `gobi/`, seed commit (README/.gitignore/CLAUDE.md skeleton) on master,
   create `develop`, branch `feat/core-bootstrap` from master. (New repo → seed commit on master is unavoidable.)
2. **Setup**: install pinned gopls + dlv (current release versions, recorded in README) via `go install`.
3. **TDD `internal/rpc`**: framing tests (back-to-back, partial reads, oversize/duplicate/malformed header) +
   `FuzzRead` + `BenchmarkFrame` (ns/op, allocs/op).
4. **TDD `internal/toolchain`** + `gobid doctor`.
5. **TDD `internal/ipc`**: dir perms, stale socket, live socket refused, symlink rejected, long path fallback,
   lock contention, handshake accept/reject, wrong-channel routing.
6. **TDD `internal/lsp`** against `fakelsp` (scriptable: delays, server→client requests, crash mid-message,
   malformed frames): ID translation across 2 clients, cancel, `workspace/configuration`, restart with unsaved
   edits replayed, client disconnect. Real-gopls test (initialize→initialized→didOpen→hover on
   `testdata/hello`) is opt-in via `GOBI_REAL_GOPLS=1`, skips if gopls missing.
7. **`cmd/gobid`** wiring + signal handling.
8. **Docs/housekeeping**: `docs/architect/gobi-architecture.md` (split, channels, handshake, broker, restart,
   socket security, perf budgets), `docs/implement/core-bootstrap.md`, `docs/claude/*`, README, CHANGELOG,
   `docs/changelog/2026-11-05-core-bootstrap.html`; commit; rebuild code-review-graph.
   Stop for user review — squash-merge to develop only after approval.

## Project lifecycle: new / open / clone / import (core in slice 3, UI in slice 4)
- **Welcome window** (shown at launch when no project is open): New Project (⌘⇧N), Open (⌘O), Clone Repository (⌘⇧K),
  Import Existing Code, recent projects (module/workspace badge, branch, Restricted flag), drag-a-folder-to-open.
  Same actions live in the File menu.
- **New Project**: templates (Command-line tool, Library, HTTP service, gRPC service, `go.work` workspace, Empty
  module, custom templates folder); name, location, module path, Go version (Auto/installed), environment profile,
  options (git init on `master`, `.gitignore`/`.env.example`/README, sample test, add to an existing `go.work`).
  The core runs `go mod init` with the selected toolchain and writes the template; shows a "Will create" file preview.
- **Open**: folder, `go.mod` or `go.work`; module-less folders open in Restricted Mode with an offer to run `go mod init`.
- **Clone**: git URL + target dir via the user's `git` CLI (credential prompts go through git's own helpers), then Open.
- **Import Existing Code**: folder without `go.mod` → create the module (module path suggested from the git remote).
- Opening any project the user has not trusted shows the **workspace trust** dialog (Trust and Open / Open in
  Restricted Mode / Cancel, optional "trust projects in parent folder"); recents store the trust state.
- Mockups added: Welcome, New Project, Workspace trust. Core API: `project/new|open|clone|import` on the control channel.

## Workspace trust (applies from slice 1 onward)
Untrusted workspace = read-only editing + gopls analysis only. Until the user explicitly trusts it, Gobi does not run:
automatic toolchain downloads, `go generate`, builds/tests, cgo/`-toolexec`, `.gobi` profiles/tasks, terminals,
debug launches. A `go.mod` `toolchain` directive is never auto-downloaded in an untrusted workspace. Trust state is
stored per workspace root and shown in the status bar.

## Slice 1 acceptance criteria (added)
- gopls absent or incompatible → `doctor` and the broker report a clear error; gobid stays up.
- Workspace trust state is enforced by the broker (no toolchain download/exec when untrusted).
- Offline mode with a missing pinned toolchain → stable diagnostic, no fallback.
- Multi-module roots and `go.work` change → broker restarts/reconfigures gopls via the epoch path (fakelsp test).
- Vendor mode, cgo-disabled files and per-file build constraints are covered by real-gopls opt-in tests on fixtures.
- CI: Go tests + fuzz smoke on every change, macOS Swift smoke build once `ui-macos/` exists; tool versions pinned in README.
- Dependency/licence review recorded in `docs/architect/` for `x/sys`, `creack/pty`, SwiftTerm, `google/pprof`.

## Follow-ups to tune (raised after slice 1 was implemented)
1. **Unix only; Windows needs another transport.** `internal/ipc` and `internal/daemon` are `//go:build unix`
   (unix socket, `flock`, `LOCAL_PEERCRED`/`SO_PEERCRED`) and `cmd/gobid` imports them, so nothing builds on Windows.
   When the Windows shell is planned: named-pipe transport behind the same `Listen`/`Dial`/`Session` API, a different
   single-instance lock (named mutex or exclusive lock file), peer identity via the pipe's client token, and a
   per-user pipe name instead of the socket directory. Split `ipc` into `socket_unix.go` / `socket_windows.go` so the
   handshake and routing code stay shared. Check the Linux build too (`peercred_linux.go` exists but is untested).
2. **Benchmarks are core-side only; Swift side and end-to-end latency are unmeasured.** Current numbers cover framing
   and id rewriting inside `gobid`. Still to measure, starting in the slice 2 spike: Swift decode time for large
   messages (completion lists, semantic tokens, workspace symbols), keystroke to paint, didChange to diagnostics,
   completion request to popup (p95), and 100k-line open. Decide from those numbers whether Gobi-owned channels
   (pprof, debugger variables) need a binary codec; if so add a `codec` field to the handshake. Keep an end-to-end
   latency harness in the repo so the budgets in the "Later slices" list are checked, not assumed.

3. **Standing rule: every requested feature gets mockups.** Mockups for JSON editing, Markdown preview, the menu bar
   and Settings (Editor, Languages) were added with the built-in JSON/Markdown language service. Still to mock up when
   they are built: Settings panes for Keymap, Terminal, Git, Advanced and a Go language pane; the Environments and
   non-local confirmation dialog; Find in Files and Rename preview.
4. **Built-in JSON and Markdown language service is implemented** (`internal/langsvc`, `gobid langserver`).
   UI work left for slice 2/4: syntax colouring (tree-sitter or a small tokenizer), the Source/Split/Preview control
   that calls `gobi/markdownPreview`, "Format Document" calling `textDocument/formatting`, Outline from
   `textDocument/documentSymbol`.

5. **Slice 2 spike result (implemented):** stock `NSTextView` on TextKit 2 is a go for the editor, provided the text view
   is a wide fixed-width view whose container tracks its width (15 ms open and 1.7 ms per keystroke on 100k lines; the
   unbounded no-wrap setup is 150x slower). Details and numbers: `docs/architect/ui-macos-spike.md`. Open items for
   slice 4: syntax highlighting cost, line-number gutter, painting and mouse behaviour, find, VoiceOver, very long
   lines, real Vietnamese IME (manual checklist), hold back didChange while marked text is active, document-version
   check for late diagnostics, and resolve the user's login-shell PATH so gopls finds `go` when launched from Finder.

6. **Slice 2 follow-up (implemented and measured):** syntax colours, line numbers, painting and mouse all work and meet the
   budgets on a 100k-line file (open 180 ms, keystroke 3.2 ms, mouse about 1 ms). One blocker found: dragging the scroller by
   pixel offset can take seconds and leaves typing at 100 ms per key; the fix (map the scroller to line numbers and scroll
   by text position) must be built in slice 4. Still to check there: GPU compositing and frame pacing, trackpad momentum,
   find in file, VoiceOver, very long lines, real input method.

## Deferred (decide later, from Codex review 2)
Editor architecture + test explorer/coverage + `go generate`/`mod tidy` tasks; rename/refactor/code actions UX;
multi-module/go.work semantics and whether one gopls stays valid; cgo/cross-compile build contexts; debugger on macOS
(dlv arm64, codesigning, attach permissions); profiling hardening (never auto-expose live pprof, bound large profiles,
keep toolchain metadata per profile); remote dev (SSH/containers/WSL) as a separate architecture; settings/keymaps,
extensions, auto-update/notarization, crash consent, opt-in telemetry, localization/accessibility audit; Git safety
(hooks, untrusted repos, confirmations).

## Skipped (and when)
- plf-go-sdk (fx/Echo/zap): service framework, not a fit for a desktop daemon.
- `gopls -remote=auto`: only if profiling shows shared-cache gains.
- msgpack/protobuf: only if benchmarks miss budget. Log rotation: when logs are persisted to disk.

## Later slices (separate plans)
2. **Vertical spike (moved up after Codex review)**: SwiftPM AppKit + TextKit 2 window, hand-assembled `.app` +
   Info.plist, ad-hoc codesign, min macOS target recorded; **open a `.go` file → start gobid/gopls → show diagnostics
   in the window**, plus a benchmark of 100k-line load/edit and Vietnamese marked-text input. Go/no-go for the editor
   architecture (TextKit 2 vs custom) before any further UI work. Highlighting: tree-sitter for lexical, gopls
   semantic tokens as overlay (decide after the spike).
3. dlv DAP channel + `go test`/`go vet` runner with streamed output; **environment profiles** (`internal/env`:
   toml load, Keychain secrets, target resolution + non-local guard) and **toolchain manager** (`internal/toolchain`
   extension: list/select/install, multi-version run matrix).
4. `ui-macos/` editor shell: file tree, diagnostics, completion via lsp channel; env + Go-version toolbar popups,
   Environments and Go toolchains windows (per the mockup), non-local confirmation dialog (not yet mocked up).
5. pprof: core aggregates profile (`github.com/google/pprof/profile`) → flame-graph tree; UI renders.
6. **Terminal**: core channel `"pty"` (PTY via `golang.org/x/sys/unix` / `github.com/creack/pty`, resize,
   login shell with user env); UI uses SwiftTerm (MIT, AppKit-native VT100/xterm emulator). Windows later via ConPTY.
7. **Git**: core shells out to the user's `git` CLI (no libgit2/go-git — same behaviour as terminal git):
   status/diff/stage/commit/branch/log/blame, gutter change markers from `git diff`, file-watch refresh.
8. Full perf harness: keystroke→paint <16ms, 100k-line open <300ms, completion p95 <100ms,
   50MB profile <2s, idle RAM excl. gopls <150MB.

## Verification
- `cd gobi/core && go test ./... && go vet ./...` green; `go test -fuzz FuzzRead -fuzztime 30s ./internal/rpc`.
- `GOBI_REAL_GOPLS=1 go test ./internal/lsp` — real gopls hover round-trip passes.
- `go run ./cmd/gobid doctor` shows go/gopls/dlv with versions.
- Start gobid twice → second exits (lock); kill -9 then restart → stale socket recovered.
- Benchmark numbers recorded in the changelog report.
