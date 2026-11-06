# Find Usages panel (IntelliJ-style "method usage")

## Spec
A usage list for the symbol at the caret, grouped by file and enclosing function, in a bottom-panel tab. Mock: Usages board
(`docs/artifact/2026-11-05-ui-mockup/Usages.dc.html`).

## Today
`CodeActions.findReferences()` (⇧F12) shows gopls' locations as a popup menu at the caret; the code lens "N references"
(`CodeLensFeed`) calls the same flow. One hit opens at once; several give a flat menu. Source lines in the menu are read
from disk (`CodeActions.swift:72`).

## Design
- New tab **Usages**: header "Usages of `Server.Start` — 12 in 4 files"; tree file → function → line (line number, source
  line with the match in bold). Filter: include tests (`_test.go`). Buttons: Rerun, Previous, Next.
- Pure grouping in `GobiModel` (`UsageGroups.build(locations, symbols)`, no Foundation) using the symbol model from
  `prerequisites-tabs-symbols.md`.
- Keys: Find Usages **⌥F7**; inside the panel Return opens the line, ⌥↓/⌥↑ next/previous. F4 stays Explorer's Jump to Source.
  Code lens click and ⇧F12 open the panel when there is more than one hit; one hit still jumps at once.
- Correct for unsaved buffers: open files are read from the live buffer, closed files from disk. The request captures URI,
  caret, symbol and document versions; superseded callbacks are dropped; the result is marked stale (with Rerun) when a
  contributing document changes; a location is validated before navigation (deleted file, moved line).
- **Enrichment phase** (enclosing function per usage): deduplicate the result files; open files reuse their versioned symbol
  snapshot; closed files are asked with limited concurrency (e.g. 4 at a time); a failed file becomes a plain "file scope" group; a
  rerun discards the whole enrichment generation. At most 5000 usages, then a "show more" row.
- **No file I/O on the main thread.** Source lines are read off the main thread in per-file batches into a line cache (each closed
  file read once); results are published on the main thread; the table callbacks only read the cache. (The popup today reads
  files on the main thread, `CodeActions.swift:72`; do not carry that over.)

## Tests (TDD, failing first)
`UsageGroupsTests` (grouping, ordering, tests filter, caps); unsaved buffer; edit during the query; deleted file;
overlapping reruns; closed files across many results, one file failing, cancellation, 500 files; instrumentation that table callbacks do
no I/O and a closed file is read once; `--selftest-usages` on a fixture where a method is used in three files including a test.

## Order and branch
After the prerequisites; branch from the prerequisites branch (stack, see the order note in `generate.md`). Squash into `develop` after approval. Update CHANGELOG, README (shortcuts),
`docs/implement/ui-mock-gap.md`, the report in `docs/changelog/`.
