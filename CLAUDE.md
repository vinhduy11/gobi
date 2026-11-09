# Gobi

A Go IDE, macOS first, built on the official Go toolchain. Read a reference file only when the task touches its topic.

## Architecture

**See [`docs/claude/architect.md`](docs/claude/architect.md)** — core daemon + native UI split, channels, gopls broker.

## Rules

**See [`docs/claude/rule.md`](docs/claude/rule.md)** — coding conventions for this codebase.

## Safety

**See [`docs/claude/safety.md`](docs/claude/safety.md)** — workspace trust, secrets, non-local target guardrails.

## Git

**See [`docs/claude/git.md`](docs/claude/git.md)** — branches are cut from `main` (or `master` where a repo has it), not only `master`.
