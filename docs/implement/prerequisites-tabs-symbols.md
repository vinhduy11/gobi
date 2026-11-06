# Prerequisites: tab ids, symbol model, stale-result guard

Work that Find Usages, Generate and the templates depend on. Do it first, in this order. Findings come from a review of the
plans against the code (checked in the files named below).

## 1. Bottom-panel tabs by id
- Today the tabs are an ordered array (`GobiApp/ProjectChrome.swift`), the selected one is stored as a raw integer
  (`SessionStore.swift`), and code selects tabs by literal index (Find 7, Output 6, Diff 5 in `ProjectWindowController.swift`).
  Adding a tab would shift every stored and hard-coded index.
- Add `PanelTabID` (`problems`, `tests`, `terminal`, `debug`, `profiler`, `diff`, `output`, `find`, later `usages`) in
  `GobiModel`; persist the id; migrate an old integer once (index → id); replace every literal; update the self-test that asserts
  eight tabs.
- Tests: migration of each old index, an unknown id falls back to Problems, the order of tabs is data.

## 2. Document symbol model
- `OutlineSymbol` (`GobiModel/QuickOpen.swift`) keeps only name, kind, one line and children; `LSPResults.swift` drops ranges and
  detail. That cannot tell "the struct under the caret", a field's type or the function around a usage.
- Add `DocumentSymbolInfo`: uri, full range, selection range, kind, detail/type, children, document version; parse it from gopls
  `textDocument/documentSymbol` and keep one snapshot per document and version in the project window.
- **Capability**: the initialize payload (`GobiClient/LSPClient.swift:103`) advertises no `textDocument.documentSymbol`. Add it with
  `hierarchicalDocumentSymbolSupport = true`, record what the server answers, and keep the flat `SymbolInformation[]` fallback
  (the parser accepts both today, `LSPResults.swift:101`); a flat answer gives no children or field types, so Generate items that
  need them are disabled and Usages groups by file only.
- **Closed files**: the snapshot is per open document and version. Usages needs symbols of files that are not open: a bounded,
  cancellable enrichment phase (see `find-usages.md`) asks `documentSymbol` per file, with a version-free cache keyed by file
  modification time.
- Tests (extend the fake LSP initialize test to check the advertised capability): nested declarations, methods with receivers, embedded fields, generics, several declarations on one line, a caret
  between declarations, stale version ignored.

## 3. Stale-result guard (rule in `docs/claude/rule.md`)
- Every asynchronous answer carries a generation or the document version and is dropped when a newer request exists.
- Done for git status (`refreshGit`), profile loading, completion and signature help. Still to do: references/implementations
  (`CodeActions.swift`), code lens counts, hover, and every new feature below.
- Tests with out-of-order replies.

## 4. gopls code-action inventory
- The parser keeps only actions that carry a workspace edit (`LSPResults.swift:90`); command-only actions are dropped and
  there is no `workspace/executeCommand` or `codeAction/resolve` path.
- First record what gopls returns for implement interface, generate test and fill struct (a probe in `gobi-probe`). Add
  `Command`, `codeAction/resolve` and `executeCommand` handling only for those. Any item gopls cannot do is built from our own
  snippet.

Mock: none (internals). Docs: update `docs/architect/ui-macos-spike.md` or `layers.md` where a layer boundary moves.
