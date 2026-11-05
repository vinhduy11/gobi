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
