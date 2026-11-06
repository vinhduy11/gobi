# Debug (Delve): plan

Mock: `Debug`. Core: the `dap` channel runs `dlv dap` for a trusted project and passes DAP messages through (done).

| Step | What | Where |
|---|---|---|
| 1 | Breakpoints and debug state model (pure) | `GobiModel`: `Breakpoints`, `DebugState`, frame/variable texts |
| 2 | DAP client | `GobiClient`: `DAPClient` (requests, responses, events over the `dap` channel) |
| 3 | Debug session driver | `GobiApp`: `DebugSession` runs the DAP dance (initialize, launch, breakpoints, configurationDone) and keeps the state; self-test `--selftest-debug` against real dlv |
| 4 | Editor | breakpoint dots in the gutter (click toggles), current line highlight, breakpoints kept per project |
| 5 | Debug panel | Continue, Over, Into, Out, Restart, Stop; call stack; variables; goroutine in the header; selecting a frame shows its variables |
| 6 | Menus and toolbar | Debug menu (F5, ⇧F5, F10, F11, ⇧F11, ⌘\\), toolbar Debug button |
| Later | Watch expressions, conditional breakpoints, goroutines list, attach to process, inline values | |

Each step: tests first for pure logic, a commit, an entry in `ui-mock-gap.md` and the changelog.

## Status
Steps 1 to 6 are built and checked by `GobiApp FOLDER --selftest-debug` against a real dlv (a main.go with `sum := a + b` on line 6
inside add; it covers the session, the Debug panel, the gutter dot and the highlighted line). Watch expressions, conditional
breakpoints, the goroutine list, attach to process, inline values and expandable variables are built too (the self-test also
attaches to a running program). Still open: evaluating expressions in a Debug console, hit counts and logpoints, editing a variable's value.
