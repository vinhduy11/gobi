# Coding rules

- General rules: `~/.claude/rule.md` (SOLID, DRY, KISS/YAGNI, naming, comments).
- TDD for every feature or fix: failing test first, then implementation.
- Go core uses the standard library unless a dependency is clearly justified; record the licence review in
  `docs/architect/`.
- Logging with `log/slog` JSON; never log source text or secrets.
- Tests that need a real gopls or dlv are opt-in (`GOBI_REAL_GOPLS=1`) and skip when the tool is absent.
- UI code follows the mockups (`docs/artifact/2026-11-05-ui-mockup/`, live canvas linked from `docs/implement/gobi-roadmap.md`):
  layout, regions, labels, controls, shortcuts and states. To deviate, change the mock first and say so. A feature with
  no mock gets its mock before its code. Known differences are listed in `docs/implement/ui-mock-gap.md`.

## Every new feature: the checklist (do not skip a step; later releases rely on it)
Order: mock → behavior contract → vectors → code (TDD) → scenarios → matrix row → docs.
1. **Mock** on the canvas (Light and Dark, sample data only); refresh the offline copy in `docs/artifact/`.
2. **Behavior contract** `docs/architect/ui-contract/<screen>.md`: states, events, exact texts and errors, keyboard, what is
   persisted and under which key. A change to the app changes this file in the same commit.
3. **Shared vectors** `ui/spec/vectors/*.json` for every pure rule (input → expected). The Swift tests read them; so must any
   other UI. No rule lives only inside a hand-written Swift test.
4. **Code, test first.** Decisions (name validation, path normalisation, ignore rules, ranking, run configuration,
   template files) go in the Go core with a wire message; the UI draws and forwards input only. Logic added to AppKit code
   needs a written reason.
5. **Scenarios**: each `--selftest-*` check is listed in `ui/spec/scenarios/` (id, steps, expected) and has a row in
   `docs/implement/ui-parity-matrix.md` (macOS / Linux / Windows: not started, passes, waived with reason).
6. **Docs**: README, CHANGELOG, `docs/implement/ui-mock-gap.md`, the report in `docs/changelog/`.

## Cross-platform parity (the macOS app must not hide behaviour Linux or Windows would lack)
- `GobiModel` and `GobiClient` stay free of AppKit, Darwin and Foundation-only APIs (`check-layers.sh`); they must build and
  pass on Linux (CI). Do not add a macOS-only call to them.
- Menus, context menus, shortcuts, settings keys and defaults, template catalogue and bottom-tab ids are data exported to
  `ui/spec/*.json` (`make spec`); never retype them. A test fails when the committed JSON is stale.
- Persist stable ids, never positions: bottom-panel tabs use `PanelTabID`, not an index; settings keys are named; a change
  to a stored value migrates the old one.
- File names and paths are checked against every target OS (Windows reserved names, trailing dot or space, length,
  case-insensitive collisions), so a project made on macOS opens elsewhere. Never assume `/`, LF, case-sensitivity, a unix
  socket, a pty, a login shell, `~/Library` or GUI-launch PATH; the platform differences table in
  `docs/architect/cross-platform.md` is the register: add a row when you meet a new one.
- Shortcuts: a new one must not collide with an existing one (`MenuSpecTests`) or with the mapped Ctrl/Alt form on Linux and
  Windows; keys scoped to a panel are declared as such.

## Generated code (project templates, Generate, design patterns)
- Output compiles, passes `gofmt` and `go vet`, and has an exact golden-file test per generator. Style sources: Effective Go
  (names, getters `Addr()` not `GetAddr()`, doc comments start with the name, early return, small interfaces), the Go
  doc-comment and errors guidance (`%w`, `errors.Is/As`, `ErrXxx`), `context` conventions. Effective Go predates modules and
  generics, so do not cite it for those.
- Templates are stdlib-only and complete offline; a template that needs a download is a post-create step with its own
  non-fatal result, never part of project creation (creation removes the folder on any error).
- Design patterns follow the Go form (functional options, `sync.Once`, middleware, `iter.Seq` only when the module's Go
  version allows), with a comment naming the pattern and noting a simpler Go idiom where one exists.
- Editor insertions are one undoable edit, formatted afterwards through LSP only if the buffer version is unchanged.

## Asynchronous results
Anything that answers later (git status, references, completion, profiles, previews) carries a generation or document
version and is dropped when a newer request exists; results for open files read the live buffer, not the disk; a result for
a document that changed is marked stale. Add a test with out-of-order replies. (Two flaky self-tests were this bug.)
