# macOS editor: fixes and follow-up work

Instructions for whoever picks this up (written so a smaller model can follow them without the earlier conversation).
Read `docs/architect/ui-macos-spike.md` first for the measurements and `docs/architect/gobi-architecture.md` for the
overall design. All work is in `ui-macos/` unless a task says otherwise.

## Rules of engagement

- Work on branch `feat/ui-macos-spike` (the spike is not merged yet). Do not merge, push, delete branches or rewrite
  history. Commit small, one task per commit. **Commit messages must not mention AI, Claude or co-authors.**
- Tests first for anything pure Swift: write the failing test, see it fail for the right reason, then fix. Swift
  Testing cannot be combined with `import Foundation` on this machine, so pure logic lives in `GobiClient` on `[UInt8]` /
  `[UInt16]` and its tests do not import Foundation. GUI behaviour is checked with the harness commands below.
- Names must say what a thing is. A repository hook rejects generic names (`data`, `value`, `buf`, `info`, `object`,
  `result`, single letters, files called `helpers`). Pick a specific name or the write is refused.
- After each task: update `CHANGELOG.md` (Unreleased) and the relevant doc under `docs/architect/`. Do not write real
  hosts, paths under a home directory, tokens or credentials into any tracked file.
- Do not claim something works unless you ran the command and saw the output. If a check is inconclusive, say so.

## Environment (every item here cost someone time)

- macOS 26, Apple silicon, Swift 6.2 from the Command Line Tools only (no Xcode). `swift build` works; run tests with
  `./scripts/test.sh` (it adds the framework flags). 41 tests must pass.
- GUI checks open real windows on the user's screen for a few seconds. That is expected.
- zsh does not split unquoted variables; macOS has no `timeout` (use `perl -e 'alarm 120; exec @ARGV' cmd ...`); use
  `pkill -x gobid` / `pkill -x GobiApp`, never `pkill -f` with text that appears in your own command line.
- AppKit offers every path-like command-line argument to `application(_:openFile:)`; never put an output path where AppKit
  can mistake it for a document (`AppDelegate` already ignores the `--snapshot` value).
- Build the daemon once: `cd core && go build -o <out>/gobid ./cmd/gobid`, then `export GOBID_PATH=<out>/gobid`. gopls
  v0.24.0 must be installed (`~/go/bin/gopls`). A Go file only gets diagnostics when a `go.mod` is above it.
- Generate the large test files: `python3 ui-macos/scripts/make-fixtures.py <out>/fixtures`. This gives `biggo/`
  (valid 100k-line program), `biggo_err/` (error on the last line) and `longline/`.
- Release builds only for numbers: `swift build -c release --product GobiApp` (also `gobi-bench`, `gobi-check`).

## Tools you have

| Tool | Command | What it checks |
|---|---|---|
| Self-test in the real app | `GobiApp FILE --selftest [--snapshot out.png]` | diagnostics, colours, gutter, mouse, scroll, typing, Vietnamese composition; the PNG can be read as an image. Env: `GOBI_SCROLL_FIRST=1` runs the scroll checks before typing |
| Verification harness | `gobi-check MODE FILE` | modes `drag` (real scroller drag), `jump [--by-line]`, `cliff [--no-fix]`, `momentum`, `longline`, `find`, `ax`, `paint`, `highlight`, `fuzz`. `--no-fix` turns the scroll remap off to get the stock behaviour |
| Benchmarks | `gobi-bench [--lines N] [--no-highlight] [--no-gutter]` | open, layout, keystroke, memory |
| Headless client | `gobi-probe FILE` | diagnostics through gobid without a window |

## What is established (do not re-derive)

1. 100k lines, release: open about 180 ms, keystroke about 3 ms, highlighting about +1.4 ms per key, mouse about 1 ms.
2. **Scroll cliff.** Scrolling to a far pixel offset (dragging the scroller thumb) takes up to 2.9 s once and leaves each
   keystroke at 80 to 205 ms, with memory growing by tens to hundreds of MB. Evidence: `gobi-check cliff FILE --no-fix`
   prints a 880 ms jump, memory 123 to 186 MB, keystrokes 205 ms afterwards. `invalidateLayout` on the whole document does
   not help (memory 455 MB, keystrokes 131 ms). A fixed line height does not help. The likely mechanism is that TextKit
   keeps the laid-out paragraphs and every edit pays per kept paragraph (unproven).
3. **Partly fixed.** `EditorClipView` (in `Sources/GobiEditor/EditorView.swift`) turns any scroll that travels more than six
   viewport heights into `scrollRangeToVisible` on the corresponding line. `gobi-check cliff FILE` then shows a 4 ms jump,
   no memory growth, keystrokes 3.7 ms. The scroll-first self-test now shows jumps 12 ms and keystrokes 4.9 ms.
4. A real drag (`gobi-check drag FILE`) goes through the remap (100 remapped jumps) but keystrokes afterwards are still
   10 to 11 ms (stock: 14.9 ms) and memory ends near 320 MB, because every place the drag stops keeps its layout.

## Tasks

Do them in this order. T1, T5, T6 are mechanical. T2, T3, T4, T7 need investigation: reproduce first, write down what you
saw, then fix.

### T1. Diagnostics wipe syntax colours (bug, mechanical)
`EditorWindowController.applyUnderlines` calls `layout.setRenderingAttributes(...)`, which replaces every rendering
attribute on the range, including the foreground colour the highlighter set. A diagnostic on `func` or a string loses its
colour. Fix: add the two underline attributes with `addRenderingAttribute` and remove only those two keys when clearing.
Acceptance: in the self-test, open `Fixtures/syntax/sample.go` with a diagnostic on a keyword (make a copy that uses an
undefined name next to `func`) and assert the foreground colour is still present at that offset; extend the `highlight`
mode of `gobi-check` the same way. Add a short test case to the self-test output.

### T2. Stale colours after closing a comment (bug, investigate)
Reported: type `/*` at the start of a line, then `*/` right after it; the lines below stay coloured as comment (or plain)
for at least 100 ms plus a viewport layout, instead of returning to normal colours. Opening `/*` did recolour the lines
below. Also reported: right after typing `xxx` in front of `var`, the word still shows the keyword colour. Start with
`gobi-check highlight Fixtures/syntax/sample.go` and read which checks FAIL; the earlier raw output is not kept, so rerun it.
Suspect `SyntaxHighlighter.refresh` (it only asks for invalidation when the changed lines extend below the edited ones, and
`invalidateRenderingAttributes` may only take effect on the next layout or display) and the validator being called before
`SyntaxIndex` has been updated. Acceptance: all `highlight` checks pass, plus a new case for each scenario above.

### T3. Scroller: remaining layout retention (main item, investigate)
Goal: after a real drag across the whole file, keystrokes stay within 1.5 times a fresh start (about 5 ms) and memory grows
by at most 60 MB. Measure with `gobi-check drag FILE` (and `--no-fix` for the baseline), and `cliff`.
Options in order of preference, try one at a time and keep what the numbers support:
1. Do not lay out while the thumb is moving. Subclass `NSScroller` (or handle the scroller's action) so that during a drag
   only the knob moves and a small label shows the line number; jump once on mouse-up through the same line mapping.
   Trade-off: no live scrolling while dragging. If that is unacceptable, throttle live jumps to a few per second.
2. Release the kept layout after a drag ends. Candidates to try: re-attaching the text content storage to a fresh
   `NSTextLayoutManager`, or resetting the text with the same string while preserving selection, scroll position and the
   undo stack. Check undo still works and the syntax index and line index still equal a rebuild (the self-test prints this).
3. A uniform-line-height scroll model: only if 1 and 2 fail.
Also make the same line mapping available as a function (`scrollToLine`) because go-to-line and search results need it.
Acceptance: the numbers above, `./scripts/test.sh` green, self-test passes in both orders (with and without
`GOBI_SCROLL_FIRST=1`), and `docs/architect/ui-macos-spike.md` updated with a before/after table.

### T4. Accessibility is unusable at 100k lines (bug, investigate)
`gobi-check ax FILE` showed `accessibilityInsertionPointLineNumber` taking about 7.8 s with the caret at the end and
`accessibilityLine(for:)` about 205 ms at 95% of the file; keystrokes were then 205 ms (the same layout retention).
VoiceOver asks for these on every selection change. Fix: subclass the text view and answer line questions from
`LineIndex` (a binary search), including the insertion-point line number, line for index, range for line and visible
character range, without touching layout. The gutter is already hidden from accessibility, which is fine.
Acceptance: each of those calls under 5 ms on the 100k-line file in `gobi-check ax`, memory flat, and a note in the doc that
a real VoiceOver pass is still needed (it cannot be automated here).

### T5. Self-test hangs on a missing file (bug, mechanical)
`GobiApp missing.go --selftest` prints "cannot read" and then waits forever. In self-test mode exit with a non-zero code
immediately when the file cannot be read. Acceptance: the command returns within a second with exit code 1.

### T6. Paint numbers are layout numbers (measurement bug, mechanical)
`window.displayIfNeeded()` paints nothing here; only `CATransaction.flush()` draws. Replace it in the self-test, in
`gobi-bench` and in the harness with a helper that calls `CATransaction.flush()`, relabel the output, rerun, and update the
paint rows in `docs/architect/ui-macos-spike.md` (a keystroke with the flush measured 5.0 ms median).
Acceptance: the gutter draw counter increases by about one per keystroke in the self-test.

### T7. Very long lines (investigate, then decide)
A 1 MB single-line JSON took about 13 s per keystroke and 550 MB. Go lines of about 3800 characters are fine (open 67 ms,
keystroke 3.4 ms, wraps at about 2980 pt). Generate files with `make-fixtures.py` and run `gobi-check longline FILE`.
First find which part dominates by opening the same file with highlighting off and the gutter off
(`EditorView(..., highlight: false, lineNumbers: false)`). Then add a "huge line" mode: when any line is longer than a
threshold you choose from the data (for example 20,000 characters), switch off the features that scale with line length,
keep typing under 100 ms, and show a one-line notice in the status bar. Acceptance: 1 MB single line keystroke under 100 ms,
the threshold and the trade-off written in the doc, the normal path unchanged (re-run the 100k-line numbers).

### T8. Inconclusive checks (best effort)
Trackpad momentum scrolling (`gobi-check momentum FILE`): synthetic phased events never moved the view in four delivery
paths. Find in file (`gobi-check find FILE NEEDLE NEEDLE`): the harness could not drive `NSTextFinder` from code. Try to
make either work; if you cannot, write down what you tried and leave them marked inconclusive.

### T9. Small hygiene
`LSPClient.requestAndWait` leaves its pending entry behind after a timeout and a late response writes to a captured
variable; remove the entry on timeout. Compare line separators: `LineIndex` counts only `\n`, while the text system also
treats U+2028 and a lone `\r` as paragraph breaks; write a test with such text and decide which side to change.

## Before you finish

Run `./scripts/test.sh`, the self-test on `Fixtures/syntax/*` and on the 100k-line file in both scroll orders, the cliff
and drag commands, and the benchmark. Put the final numbers in the doc, update `CHANGELOG.md`, and report what you changed,
what you measured and what remains unverified. Leave merging to the owner.

## Status after this round

| Task | Status | Where |
|---|---|---|
| T1 underline keeps colour | DONE | `DiagnosticUnderlines`; highlight check and self-test check pass |
| T5 self-test hang | DONE | exits 1 in 0.6 s |
| T6 paint measurement | DONE | `flushPendingPaint()`; gutter draws 50 for 50 keystrokes |
| T9 hygiene | PARTIAL | pending-request leak fixed (unit tests). Separator checks still FAIL; see the spike doc for the findings and the LineIndex decision |
| T2 stale colours | PARTIAL | bug reproduced, cause not found; the validator/refresh experiments are recorded in the spike doc |
| T4 accessibility | DONE (VoiceOver pass still needed) | `EditorTextView`; all line queries under 0.01 ms |
| T7 very long lines | PARTIAL | colouring skipped above 20,000 characters (13 s to 151 ms); the 100 ms target is not met, the remaining cost is TextKit layout of one paragraph |
| T3 scroller | DONE for the target numbers | deferred jump on drag end; keystrokes after drag 2.1 ms, memory +26 MB |
| T8 find and momentum | BLOCKED (inconclusive) | find: NSTextFinder picks the first match; own-finder variant crashes; momentum not retried |
