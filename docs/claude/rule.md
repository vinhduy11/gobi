# Coding rules

- General rules: `~/.claude/rule.md` (SOLID, DRY, KISS/YAGNI, naming, comments).
- TDD for every feature or fix: failing test first, then implementation.
- Go core uses the standard library unless a dependency is clearly justified; record the licence review in
  `docs/architect/`.
- Logging with `log/slog` JSON; never log source text or secrets.
- Tests that need a real gopls or dlv are opt-in (`GOBI_REAL_GOPLS=1`) and skip when the tool is absent.
