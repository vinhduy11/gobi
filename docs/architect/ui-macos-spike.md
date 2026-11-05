# macOS editor spike: findings

Goal of slice 2: prove "open a file, start gobid and the language server, show diagnostics in an AppKit window",
measure a large file, and decide whether stock `NSTextView` on TextKit 2 can carry the editor.

Environment: macOS 26.6.2, Apple silicon (8 cores), Swift 6.2 from the Command Line Tools only (no Xcode),
release builds. Minimum deployment target recorded as macOS 14.

## What was built (`ui-macos/`)

- `GobiClient` (Foundation only): LSP frame decoder on `[UInt8]`, incremental UTF-16 line index, unix-socket
  connection, handshake, a small LSP client, and gobid discovery that starts the daemon when none answers.
- `GobiApp`: window with a TextKit 2 text view, a problems list and a status line. Typing is sent to the server as
  incremental edits (or full text when the server asks for it); diagnostics are drawn as TextKit 2 rendering
  attributes, which never touch the text storage. Works for Go, JSON and Markdown through the same code.
- `gobi-probe`: headless end-to-end check (connect, initialize, open, wait for diagnostics, hover, format).
- `gobi-bench`: the measurements below. `--selftest` on `GobiApp` runs the same checks inside the real window.
- `scripts/make-app.sh`: builds `dist/Gobi.app` with `gobid` bundled and signs it ad hoc.
- 22 Swift tests (frame decoder, line index with a randomized equivalence test) via `scripts/test.sh`.

## The main finding: one layout setting decides everything

Stock `NSTextView` with 100k lines (4.9 MB):

| Text view setup | Open (first layout) | Scroll to end | Keystroke (median / p95) | Memory |
|---|---|---|---|---|
| Unbounded or fixed-width container that does not track the view (the usual "no wrap" code setup) | 2293 ms | 1858 ms | 352 / 446 ms | 812 MB |
| Container tracks the view width (default wrapping) | 15 ms | 3.7 ms | 1.70 / 2.02 ms | 160 MB |
| Wide fixed text view (3000 pt), container tracks it, no resizing, scrolls sideways (chosen) | 14.5 ms | 3.6 ms | 1.72 / 2.24 ms | 160 MB |

With the first setup cost grows with line count (10k lines: 205 ms to open, 27 ms per keystroke), so TextKit 2 is laying
out the whole document. Only the container-tracks-the-view setups stay lazy. Lines longer than the view width wrap.

## Through the real app (100k-line, 1.9 MB Go program that compiles and runs)

| Step | Result |
|---|---|
| `go run` of the program | 3.7 s including compile, prints `total: 37345` (correct) |
| Connect to gobid (daemon started on demand) | 352 ms cold, 136 ms with the daemon running |
| First diagnostics from gopls | 1.85 s cold, 0.64 s with gopls caches warm |
| Error on the last line (100,013) underlined | under 0.1 ms |
| 100 keystrokes in the middle of the file | median 2.1 ms, p95 2.7 to 3.6 ms, worst 45 ms (one outlier) |
| Incremental edits sent to gopls | 108, accepted |

## Protocol side (Swift)

| Item | Result |
|---|---|
| Line index build, 100k lines | 3.3 ms; incremental update 0.04 ms |
| Frame decode of an 861 KB completion list | 0.2 ms |
| JSON decode of that message | 4.8 ms (`JSONSerialization`), 4.5 ms (`JSONDecoder`, two fields) |

JSON is not a bottleneck on the Swift side at this size either. Together with the Go-side numbers there is no case
for a binary codec yet.

## Vietnamese input

An automated check drives the text view the way the built-in Telex input method does (growing marked text, then a
commit) and confirms the final text, no leftover marked range and a line index that still matches. **A real input
method was not tried.** Manual checklist: type "tiếng Việt" with Telex and VNI in the editor, accept and cancel a
composition, undo after a composition, type inside a Go string next to an emoji.

## Decision

Go: build the editor on stock `NSTextView` with TextKit 2 using the third setup above. It meets the keystroke,
open and memory budgets on a 100k-line file with margin.

Not yet measured, and the next risks: syntax highlighting cost, a line-number gutter, painting (the numbers are layout
only), selection and scrolling by mouse, find in file, VoiceOver, files with very long lines, and diagnostics that
arrive after the text moved (they are applied to the current text without checking the document version).

## Issues found

1. **Testing on the Command Line Tools**: `swift test` needs extra framework flags (`scripts/test.sh`), and Swift
   Testing cannot be used together with `import Foundation` there. The frame codec therefore works on `[UInt8]`.
2. **Launched from Finder, PATH lacks Go**: gobid starts gopls, which needs the `go` command. A GUI app inherits a
   minimal PATH, so gobid needs the user's login-shell environment (or the Go toolchain manager) before this ships.
3. **Marked text is sent to the server**: one composed word produced seven didChange messages. Hold edits back while
   `hasMarkedText` is true.
4. **Bundle identifier** `dev.gobi.app` is a placeholder; real signing and notarization are not set up.
5. The self-test opens a window on screen for a few seconds.

## Follow-up: syntax colours, line numbers, painting, mouse

Checked on the same 100k-line, 1.9 MB Go program, release build, in the real window (`GobiApp --selftest`), plus the
isolated numbers from `gobi-bench`.

### What was built

- Per-line lexers for Go, JSON and Markdown (`SyntaxTokenizer.swift`) and a `SyntaxIndex` that stores each line's start
  state and tokens and re-lexes only the touched lines, plus following lines until the state matches what it was
  (opening a `/*` or a raw string re-lexes down to its end). 41 Swift tests including a randomized check that 1500 edits
  per language always equal a full rebuild.
- Colours are applied lazily as TextKit 2 rendering attributes through `renderingAttributesValidator`, so only paragraphs
  that are laid out get coloured (1128 for the whole benchmark) and the text storage is never touched.
- A line-number gutter that draws only the paragraphs in the viewport.
- `GobiEditor`: one shared `EditorView` used by the app and the benchmarks, so both measure the same setup.

### Numbers (100k lines)

| Measure | Result |
|---|---|
| Tokenize the whole file once (part of opening) | 128 ms |
| Re-lex an edited line | under 0.01 ms |
| Open the editor (line index, syntax index, text) | 177 to 182 ms (budget 300 ms) |
| Keystroke: edit, indexes, layout (median / p95) | 3.2 / 3.7 ms in the app, 3.2 / 3.8 ms isolated |
| The same plus painting the window | 3.7 ms median (isolated bench: 3.7, but its window is invisible so treat that as layout) |
| Cost of highlighting per keystroke | about 1.3 to 1.5 ms (1.9 ms without, 3.4 ms with) |
| Cost of the gutter per keystroke | about 0.25 ms |
| Memory with the file loaded | 226 MB, of which the syntax index is about 24 MB |
| Paint the whole editor to a bitmap (CPU path) | 4.3 ms median |
| Mouse: click, double, triple, shift-click, drag | 0.9 to 1.5 ms each, every selection correct |
| Scroll wheel, 100 events | 1.9 ms median, 3 ms worst |

The images written by `--snapshot` were inspected by eye for Go, JSON and Markdown: keywords, built-ins, strings, runes,
numbers, line and multi-line comments, raw strings, JSON keys, Markdown headings, list markers, inline code and fenced
blocks all take the right colour, and the line numbers line up with their lines.

### A performance cliff: scrolling to a far pixel offset

This section corrects the first version, which said typing first avoids the problem. An independent check showed that
it does not: the self-test only measured keystrokes before the jumps in that order.

Scrolling a 100k-line document to a pixel offset near the end (what dragging the scroller thumb does) makes TextKit 2
lay out and keep the paragraphs above the target:

| Case (100k lines, release) | Far jump | Keystrokes afterwards | Memory |
|---|---|---|---|
| Baseline, one jump to 96% by pixel offset | 880 ms | 205 ms median (fresh: 3.3 ms) | 123 to 186 MB |
| Baseline, jumps to 96% and 92% in a batch of 20 | 0.5 to 2.9 s | 80 to 100 ms | grows |
| Typing first, then the same jumps | 616 ms | 88 ms | grows |
| `invalidateLayout` on the whole document afterwards | 16 ms | 131 ms | 455 MB (worse) |
| Fixed line height | worse | worse | |
| **Large jumps remapped to text positions** (`EditorClipView`) | 4 ms | 3.7 ms | no growth |
| Real scroller drag through the tracking loop, stock | no stall (ticks median 15 ms) | 14.9 ms | 399 MB |
| Real scroller drag, with the remap | no stall | 10 to 11 ms | 316 to 322 MB |

Reading: the cost of an edit grows with the number of laid-out paragraphs TextKit keeps (about 96k paragraphs: 205 ms; a
drag that visits about 100 places, roughly 6k paragraphs: about 8 ms extra). That is a strong correlation, not a proven
mechanism. Remapping large jumps to text positions removes the single far-jump case completely, but a continuous drag
still leaves layout behind at every place it stops, so keystrokes after a drag cost 3 to 4 times a fresh start (still under
16 ms). Further mitigation is described in `docs/implement/ui-macos-fixes.md`.

### Issues found

1. **Opening from the command line hung the app.** AppKit offers every path-like argument to `application(_:openFile:)`,
   including the `--snapshot` target, which did not exist, so an error alert waited for a click forever. Fixed: one
   place handles command-line paths, option values are ignored, and scripted runs never show a modal alert.
2. **`NSRulerView` hid the first characters of every line.** On this macOS the scroll view did not move its clip view
   aside for the ruler (clip frame x stayed 0 although the ruler was 52 pt wide), even after `tile()`. The gutter is now a
   separate view beside the scroll view, and the self-test checks that the text starts to its right.
3. A Go file with no `go.mod` produced no diagnostics from gopls, so test fixtures need one.

### Still not covered

Painting is measured on the CPU path into a bitmap. An independent check found that `window.displayIfNeeded()` paints
nothing in any condition (alpha 1, alpha 0, ordered out), so the "plus paint" numbers above are layout numbers; only
`CATransaction.flush()` actually draws. Measured with the flush, a keystroke costs 5.0 ms median (about 2 ms of it
painting). GPU compositing, frame
pacing on ProMotion displays and trackpad momentum scrolling are not measured. The scroller is exercised by position
jumps, not by a real drag. Also untested: selection by mouse across a very large range, find in file, VoiceOver, very
long lines, and a real input method.

## Fix log (tasks from `docs/implement/ui-macos-fixes.md`)

| Task | Before | After |
|---|---|---|
| T1 diagnostic underline keeps syntax colour | `gobi-check highlight` check "setRenderingAttributes for an underline keeps the keyword colour": FAIL, runs `[0+4:plain+underline]` | ok, runs `[0+4:keyword+underline]`; app self-test check "an underline on the first token keeps its colour" ok |
| T5 self-test on a missing file | `GobiApp missing.go --selftest` prints "cannot read" and waits (killed by the 10 s alarm) | exits with code 1 in 0.6 s |
| T6 paint numbers | `displayIfNeeded()` used for paint; self-test gutter draws 0 for 50 keystrokes | `flushPendingPaint()` (CATransaction.flush); gutter draws 50 for 50 keystrokes; 100k bench: keystroke + paint median 5.38 ms (p95 6.15 ms), paint of the whole editor (CPU) 4.3 ms earlier run, layout-only keystroke 3.83 ms median |

The paint rows in the sections above that say "plus painting" were layout-only numbers. The paint rows with the flush are the ones to use.
| T9a pending LSP request left behind after timeout | `requestAndWait` removed nothing on timeout; late response wrote into a captured variable | `PendingReplies` (unit tests: timed-out entry removed, late reply finds nothing); `requestAndWait` removes its entry on timeout |
| T9b separators: LineIndex vs TextKit | `gobi-check highlight` section (e): U+2028, lone CR, CRLF and LF-only control all FAIL | pass after the T2 fix (same cause, not the separators); see the findings below |

### T2 findings: stale colours (fixed) and T9b separators

- **Visible on screen, not a harness artifact.** `gobi-check highlight FILE --png-dir DIR` writes PNGs of the editor after
  the edits, with and without a settle step (`CATransaction.flush()` and a 50 ms run-loop spin). Before the fix, after
  `/*` then `*/` the line below (`package sample`) was drawn plain instead of keyword-coloured, and after typing `x` in
  front of `var short = 5 // short` the `5` was black and the comment colour started one character late. Settling did
  not change either picture.
- **Cause.** Instrumenting the validator with a call stack showed it runs inside `NSTextStorage.endEditing` ->
  `NSTextContentStorage.synchronizeTextLayoutManagers` -> `NSTextLayoutManager._fixSelectionAfterChange...` ->
  `ensureLayoutForRange` (for the caret), with `SyntaxIndex` already updated. The colours it writes there are then moved
  by the edit's length when the layout manager adjusts its stored rendering attributes for the edit: after inserting one
  character the number and comment runs sat at 14 and 16 instead of 13 and 15; after `/*` (two characters) they were two
  units late. For a replaced range (setting the whole text) they were dropped. The paragraph then counts as validated,
  so TextKit does not call the validator again.
- **Invalidation alone does not help:** `invalidateRenderingAttributes(for:)` followed by `layoutViewport()` removed the
  colours of a paragraph that stays laid out and did not call the validator again (runs empty afterwards). This is why
  the earlier experiments (invalidating in the text storage delegate, which runs before the synchronisation) gave no gain.
- **Fix.** `EditorContentStorage` (an `NSTextContentStorage` subclass, now built explicitly with its layout manager and
  container in `EditorView`) calls back after `processEditing`, or after the outermost `performEditingTransaction` when
  the edit happens inside one (typing does). `SyntaxHighlighter.recolourAfterEdit` invalidates the changed lines (edited
  lines plus the lines below whose tokens changed) and colours the ones laid out in the viewport directly. This replaces
  the asynchronous invalidation of the lines below.
- **Harness bug.** `colour(atOffset:)` returns the next coloured run when nothing is stored at the offset, so "is plain"
  checks could read a neighbour's colour. Those checks now use `colourContaining`, and a new check verifies that each
  token is coloured at its first unit and the unit before it is not.
- **Results.** `gobi-check highlight Fixtures/syntax/sample.go`: 10 FAIL before (with the corrected reader), 0 FAIL and
  34 ok after, including the `*/` case, `xvar` on short and 3000-character lines, and the U+2028, lone CR, CRLF and LF
  separator cases, which failed for the same reason (the text was replaced and the validator's colours were dropped), not
  because of the separators. 100k lines (`gobi-bench`, release): keystroke median 3.47 to 3.54 ms with the fix, 3.77 ms
  without; memory 339 MB in both. Self-test on 100k lines passes in both orders (keystrokes 3.6 ms, scroll-first 4.9 ms).
- **Open.** A `beginEditing`/`endEditing` batch on the text storage (only the harness does this) makes TextKit log
  "enumerate while editing" during the recolour; the colours after such a batch are not checked. The earlier finding that a
  lone CR counts as a line break for LSP and not for `LineIndex` (T9b) is a separate issue and was not revisited. A real keyboard session was not tried;
  the evidence is the harness PNGs.

| T4 accessibility line queries (100k lines, `gobi-check ax`) | caret line 7.9 s at top, 18.4 s with the caret at 95%; line for index 210 ms; range for line 84 ms; keystroke after the queries 220 ms median; memory at end 963 MB | `EditorTextView` answers from `LineIndex`: caret line 0.00 ms (both places), line for index 0.0 ms, range for line 0.0 ms; keystroke after the queries 3.75 ms median; memory at end 122 MB |

T4 notes: `accessibilityRange(forLine:)` now returns the line without its terminator (TextKit's answer included it); this is a
deliberate choice, check it with VoiceOver. A real VoiceOver pass is still needed; it cannot be automated here. The editor view is now
built with a plain `NSScrollView` and `EditorTextView` instead of `NSTextView.scrollableTextView()`; TextKit 2 is still active.
| T7 1 MB single-line JSON, keystroke at the end (`gobi-check longline`) | 13.7 s median, memory 485 MB after open, 873 MB after typing | highlighting off on that line: 151 ms median (still above the 100 ms target). Lines over 20,000 characters are not coloured (`EditorDocument.overlongLineLimit`) |

T7 findings: with highlighting off the 1 MB line still costs 147 ms per keystroke, so the remaining cost is TextKit laying out one
paragraph of 3,948 visual lines on each edit, not the colouring. The threshold of 20,000 units is a judgement: 3,800-character Go
lines are unaffected (open 67 ms, keystroke 3.4 ms in the earlier measurements). Not done: a hard wrap or a non-TextKit view for
huge lines; that is the next lever if the 100 ms target matters. Lines over the limit keep their text and wrap as before.
| T3 real scroller drag across the whole 100k-line file (`gobi-check drag`) | 100 remapped jumps while dragging; keystrokes after 10.35 ms median; memory +139 MB (end 322 MB) | one jump when the drag ends; keystrokes after 2.1 ms median (p95 2.4 ms); memory +26 MB (end 138 MB) |
| T3 self-test, both orders | jumps 12 ms, keystrokes 4.9 ms (earlier) | scroll-first: passes; typing-first: passes; 100 keystrokes 3.6 ms median, scroller jump with paint 14.9 ms median |

T3 trade-off: the text does not move while the thumb is dragged; it jumps to the final place on release. Small steps (within six
viewport heights) still scroll live. Option 2 (releasing layout) was not needed, so it was not tried. The `cliff` numbers
(jump 4 ms, keystrokes 3.2 ms after) are unchanged.

### T8 inconclusive checks (best effort)

- `gobi-check find FILE total func`: `NSTextFinder` selects the first occurrence instead of the next match after the caret (selection stays {0, 0}), so both "nextMatch" checks FAIL. The find bar shows and the search string is set through the find pasteboard, as the harness already did. Tried `--own-finder` (a separate `NSTextFinder` with the text view as client): the process crashed (exit 139) right after "own NSTextFinder client set: false". Not resolved. The harness reports these as FAIL, which is the honest state.
- `gobi-check momentum FILE`: not retried in this round; the earlier result (synthetic phased events never move the view in four delivery paths) stands and is still inconclusive.
- A real trackpad and a real find bar pass are still needed by hand.

### Round 3: find, scrolling, long lines, lone CR

- **Lone CR.** Line breaks are `\n`, `\r\n` and a lone `\r` in both the Swift `LineIndex` and the Go side (`internal/textlines`). An edit can join a CR and an LF into one break or split one, so `LineIndex.replace` re-reads one unit on each side; a 4,000-step randomized test with `\r` in the alphabet always equals a rebuild.
- **Scroller drag.** Jumps are throttled to one per 0.12 s while the thumb moves and the last one is applied on release: 15 jumps in a 1.65 s drag, keystrokes after 3.6 ms, memory +50 MB. Quirk: releasing at 30% can leave the thumb at about 25%.
- **Continuous scrolling.** Wheel-like steps through 99k lines do not slow later typing (2.5 to 3 ms), so no layout trim was built. Real trackpad momentum events cannot be synthesized; check by hand.
- **Long lines.** Edit cost grows with the characters in the edited paragraph (about 0.1 ms per 1,000 characters; the wrap width makes no difference): 100k 15 ms, 250k 30 ms, 500k 55 ms (89 ms with paint), 1M about 100 ms. Files with a line over 550,000 characters open read-only with a notice.
- **Find.** `NSTextFinder` could not be driven from code (selection stayed at the first match), so Gobi has its own find bar: `NSString.range(of:)` from the selection, wrap at the ends, selection and scroll by text position. 1.3 ms median per step on the 100k-line file, no slowdown for typing afterwards.
