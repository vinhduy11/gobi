# Logging

Both programs log to one folder: `~/Library/Logs/Gobi/` (mode 0700). `GOBI_LOG_DIR` replaces it; self-tests set it to a
scratch folder, and a self-test run without it gets a temp folder, never the real one.

| File | Written by | Format |
|---|---|---|
| `gobi.log` | the app (`GobiClient.AppLog`) | `2026-11-06T10:15:30.123Z LEVEL message`, levels INFO, WARN, ERROR |
| `gobid.log` | the daemon (`core/internal/logfile`) | `log/slog` JSON, one object per line; level switchable in Settings > Advanced |
| `running` | the app | marker: present while Gobi runs, removed on clean quit |

`gobid serve -log FILE` picks the file (`-` is stderr). The app starts the daemon with the default, so it writes its own file.

## What is logged
- App: start (version, build, commit, macOS, architecture), clean quit, gobid connection failures and starts, missing
  go/gopls/dlv, run, debug, terminal and git channel errors, a gobid restart, uncaught Objective-C exceptions (name, reason,
  call stack), fatal signals.
- Daemon: start (version, commit, pid, Go runtime, os/arch, socket folder name), clients attaching and detaching, tool
  problems, recovered panics with their stack.

## Rotation
Files are private (0600). At 2 MB the file becomes `.1`, `.1` becomes `.2` and so on up to `.4`; the oldest is deleted.
Writers never fail the program: if the disk is full or the folder is gone, lines are dropped.

## Privacy
No file contents, environment values, secrets or command lines with arguments. A path is logged as its last element only:
the daemon's slog handler and `AppLog` both reduce absolute paths in messages and errors (`Redact`, `LogRedaction`). Stack
traces are left as they are (they hold source paths of Gobi, not of the user's project). Copy Diagnostics applies the same
reduction to the whole text.

## Reading a crash
1. `gobi.log`: the last lines. `FATAL signal N Gobi <version>` means a fatal signal (11 SEGV, 6 ABRT, 10 BUS, 4 ILL, 8 FPE,
   5 TRAP); `uncaught exception` lines carry the Objective-C name, reason and call stack. The handler re-raises the signal,
   so macOS still writes its own report.
2. The macOS crash report in `~/Library/Logs/DiagnosticReports/` (`GobiApp-<date>.ips`) has the full thread stacks.
3. `gobid.log`: `panic recovered` lines (with `stack`) mean one client session died but the daemon stayed up.
4. The next start logs `previous run did not exit cleanly` when `running` was left behind, and shows a notice with Reveal Logs
   (never in a self-test).

Help > Copy Diagnostics puts versions, tool paths, daemon state and the last 60 lines of both logs on the pasteboard.
