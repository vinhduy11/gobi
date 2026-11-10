# Appearance: matching JetBrains One Dark and Solarized Dark

Goal: the leftovers after the first Appearance slice, so Gobi's themes look like the JetBrains screens they were sampled from.

| # | Item | Done when |
|---|---|---|
| 1 | Tab strip colour per theme | Solarized Dark's strip is `#092531`, darker than the editor; other themes keep the editor colour. `AppTheme.tabStrip` is tested. |
| 2 | Terminal ANSI colours per theme | Solarized themes use the canonical Solarized 16 colours; others keep the soft set. Tested on the palette lookup. |
| 3 | File-type icons | `.html` gets a green `<>`, `.json` a purple `{}`, as in the JetBrains tree. |
| 4 | Island layout | Sidebar, editor column, bottom panel and inspector are rounded panels (radius 8) with gaps between them and a margin around, over the frame colour. |

Order: 1, 2, 3 (small, tested), then 4 (layout), then a window self-test run and a snapshot check.

Out of scope: Islands, One Light, Solarized Light and High Contrast sampling (needs screens of those themes); Accessibility and UI Options settings.

## Semantic highlighting

JetBrains draws types, functions, parameters, fields, constants, packages and annotations in their own colours. Gobi's lexer cannot tell them apart, so gopls' semantic tokens are overlaid on the lexer's colours.

| Piece | Where |
|---|---|
| Ask gopls for tokens (off by default, `ui.semanticTokens`) | `core/internal/lsp/broker.go` `withSemanticTokens` |
| Advertise the token types and modifiers gopls uses, read its legend, request `semanticTokens/full` | `LSPClient`, `LSPQueries`, `LSPResults.semanticTokenData` |
| Decode the relative data into per-line tokens; keep them aligned while typing | `SemanticTokens`, `SemanticOverlay` (GobiModel) |
| New token kinds and per-theme colours sampled from the JetBrains screens | `SyntaxKind`, `SemanticColors`, `SyntaxTheme` |
| Paint over the lexer's colours; ask again after typing pauses | `SyntaxHighlighter`, `SemanticTokensFeed` |

Not done: the receiver (`this` in JetBrains) arrives from gopls as a plain parameter, so it takes the parameter colour.

## SwiftTerm fork

SwiftTerm 1.5.1 is vendored in `ui/macos/Vendor/SwiftTerm` and patched where the bugs are, instead of filtering input and output around it. See `VENDORED.md` there for the patch list; tests are in `Tests/TerminalForkTests`.
