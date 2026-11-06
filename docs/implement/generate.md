# Generate (right-click, ⌃N) and design patterns

## Spec
IntelliJ-style **Generate…**: insert ready-made Go code at the caret or create it in a folder, including the classic design
patterns. Mock: Generate board (`docs/artifact/2026-11-05-ui-mockup/Generate.dc.html`) and Context menus board.

## Entry points
- Editor and Explorer context menus: **Generate…** (Explorer: Generate ▸ for a folder); Code menu; shortcut **⌃N** (⌘N is File >
  New File). Entries are data in `ContextMenuSpec`/`MenuSpec` (`GobiModel/MenuSpec.swift`), so the menu test keeps rejecting
  duplicate shortcuts.
- Items depend on the caret: in a struct (constructor, getters and setters, `String()`, error type, functional options); on a
  function (table-driven test); in an empty file (`main()`, HTTP handler); implement interface and mock of an interface;
  Design Pattern ▸ (below). On a folder: handler, consumer, repository, config loader, worker with graceful shutdown.

## Design
- **Generation lives in the Go core** (rule: template-file decisions are core decisions). New package `core/internal/generate` and three
  control messages (additive, new field numbers; document in `wire-protocol.md`): `generate/list` (items that apply to a context:
  file path, caret, symbol kind and name, field list), `generate/preview` (final text for the dialog) and `generate/render` (the edits
  to apply, or for a folder item the files to create). `GobiModel` keeps only presentation state (the popup list, selection, the
  dialog form). The UI sends the symbol facts from the symbol model in `prerequisites-tabs-symbols.md`; core never parses UI state.
- Design patterns are core templates rendered with Go's `text/template`; goldens are Go tests that write the output into a temp module
  and run `gofmt -l`, `go vet` and `go test` (so "compiles" is checked by the real toolchain).
- **Insertion is one undo step by construction.** `EditorPane.apply` opens an undo group per call (`EditorPane.swift:140`), so a later
  formatting or organize-imports call would be a second step. Therefore core returns the final text: it renders the snippet,
  formats it with `go/format`, and edits the import block itself with `go/ast` (stdlib, no LSP round trip, no new dependency).
  The UI applies the whole edit set in a single `apply`. The request carries the document version; a changed buffer discards the
  reply. LSP formatting and organize imports are not used by Generate.
- **gopls first where it can**: implement interface, generate test and fill struct use gopls code actions only after the
  inventory in the prerequisites; otherwise our own snippet.
- **Getters and setters**: `Addr()` and `SetAddr(v)`, never `GetAddr()`; only unexported fields the user ticks.
- **`String()`**: the verb follows the field type (`%s` for string and named string types, `%d` for integers, `%t` for bool, `%v`
  otherwise) and never formats the receiver itself.

## Style rule matrix
Effective Go covers gofmt, package and interface names, MixedCaps, getter naming, early return and doc comments. It predates
modules and generics, so other rules cite other sources: Go doc-comment guidance, the errors guidance (`%w`, `errors.Is/As`,
`ErrXxx`, error types `XxxError`), `context` conventions (first parameter), Go Code Review Comments. Tests are compile + `gofmt -l`
+ `go vet` and an exact golden file per generator; no broad "reject any `Get` prefix" lint.

## Design patterns in Generate (reference: https://refactoring.guru/design-patterns)
Generate > **Design Pattern ▸** lists the 22 classic patterns in three groups; each one inserts an idiomatic **Go**
version, not a class-based copy (Go has no inheritance; Effective Go favours small interfaces and composition).
| Group | Pattern | Go form generated |
|---|---|---|
| Creational | Factory Method | `NewX(kind)` returning an interface, or a `map[string]func() X` registry |
| | Abstract Factory | interface of constructors + one struct per family |
| | Builder | functional options (`type Option func(*T)`, `WithX`) — the Effective Go/Go-community form; plus a chained builder variant |
| | Prototype | `Clone() T` deep copy method |
| | Singleton | package-level value behind `sync.Once` with `Instance()`; doc comment warns about global state |
| Structural | Adapter | struct embedding the adaptee, implementing the target interface |
| | Bridge | abstraction struct holding an implementor interface |
| | Composite | interface + node holding `[]Component` |
| | Decorator | `func(Handler) Handler` middleware / wrapper struct embedding the interface |
| | Facade | struct that wires subsystems behind a few methods |
| | Flyweight | shared immutable values in a `sync.Map`/map pool |
| | Proxy | struct with the same interface, lazy init / caching / access check |
| Behavioral | Chain of Responsibility | handler chain via `Next` or middleware slice |
| | Command | `Command` interface (`Execute`), optional `Undo`, invoker with history |
| | Iterator | `iter.Seq[T]` / `iter.Seq2` range-over-func (Go 1.23+); a `Next()` form for older toolchains by project Go version |
| | Mediator | mediator interface; colleagues hold it |
| | Memento | `Snapshot()`/`Restore()` with an unexported state type |
| | Observer | subscribe/notify with channels or callbacks, with unsubscribe and no goroutine leak |
| | State | state interface; context holds current state and a `Transition` |
| | Strategy | interface or `func` type, injected through the constructor |
| | Template Method | struct of step funcs / interface steps + `Run()` that orders them (composition instead of inheritance) |
| | Visitor | `Accept(Visitor)` + visitor interface with one method per node type |
Dialog asks the pattern's names (type name, interface name, method list) with a live preview of the files, inserts into the
current file or creates `<pattern>.go` in the package. Rules: names follow the file's package; honors the module Go
version (iter.Seq only from 1.23); every output compiles, passes gofmt and `go vet`, and has an exact golden-file test per
pattern (22 goldens) plus a generated example test that exercises it. A short comment names the pattern and links to
its refactoring.guru page, with a note when Go has a simpler idiom (Singleton, Iterator, Strategy). Mock: Generate board,
"Design Pattern ▸" submenu; the parameter dialog and preview are drawn on the same board in the next mock round.

Implemented in core (stage 4c): `creational.go`, `structural.go`, `behavioral.go` in `core/internal/generate`, one `patternDef` per
pattern (parameters, template, simpler-idiom note); `patterns.go` holds parsing, validation and placement. Patterns are offered
where the caret is outside any declaration (file or empty file/folder). Stubs the user must fill (adapter, bridge, composite,
factory method, strategy) have named results, a TODO comment and a bare return. Map fields in Prototype use `maps.Clone` (Go 1.21+).

## gopls inventory
Recorded with a real gopls v0.24.0 (`TestGoplsCodeActionInventory` in `core/internal/daemon`, opt-in with `GOBI_REAL_GOPLS=1`,
skipped when gopls is absent; run with `-v` for the table). The probe declares `codeActionLiteralSupport`, `resolveSupport` for
`edit`, `workspace.applyEdit` and `documentChanges` with resource operations, which is what the UI would declare.

| Item | gopls action | `codeAction` answer | What it takes to get the edit |
|---|---|---|---|
| Implement interface | quickfix "Declare missing methods of Store" (`quickfix`) | no `edit`, no `command`, only `data` | `codeAction/resolve` returns a `WorkspaceEdit` (`documentChanges`, one text edit in the file). It exists **only when a type-error diagnostic is in the request context** (`*Mem does not implement Store`), not for a bare type name. |
| Generate test | "Add test for Divide" (`source.addTest`) | `command` `gopls.add_test`, no `edit`, no `data` | `workspace/executeCommand`; the edit does not come back as the result (`null`) but as a **server-to-client `workspace/applyEdit` request**: a `create` resource operation for `calc_test.go` plus a text document edit with 3 edits. Fails with "package has type errors" when the package does not compile. |
| Fill struct | "Fill Server" (`refactor.rewrite.fillStruct`) | no `edit`, no `command`, only `data` | `codeAction/resolve` returns a `WorkspaceEdit` with one text edit. Needs the caret inside the `{}` of a composite literal. |

Conclusions:
- The current parser keeps only actions with an `edit`; **none of the three arrives that way**. Two need `codeAction/resolve`
  (implement interface, fill struct) and one needs `workspace/executeCommand` plus answering `workspace/applyEdit` (generate test).
- Implement interface cannot be driven from a menu entry "pick an interface for this struct": gopls offers it as a quickfix for an
  existing error. To use it Generate would have to insert `var _ Iface = (*T)(nil)` first and then request the quickfix, which is
  two edits (two undo steps) and a round trip. Decision for stage 4b: build "Implement interface" from our own snippet (the
  mock generator already renders method sets), and keep gopls only for fill struct, where it is the right tool.
- Generate test: gopls creates `<file>_test.go` itself and only for a compiling package. Decision: Generate keeps its own
  table-driven test (works in a package with errors, one reviewed style, no `applyEdit` plumbing). gopls' Add test stays
  reachable from the normal code-action list; if the UI later shows it, the broker must forward the `workspace/applyEdit`
  request to the UI and relay the reply.
- Fill struct: needs `codeAction/resolve` in the UI client (`resolveSupport: edit`). Small, and worth doing in 4b.
- Not needed: `Command` handling beyond what Generate test would require; the 4b UI work therefore adds `codeAction/resolve` only.

Owner decision (approved): Implement interface and Generate test are built from our own snippets, as recommended above; gopls is used only for Fill struct (`codeAction/resolve`).

## Tests (TDD)
Go: one golden per item and per pattern (temp module: gofmt, vet, test), mixed field types for `String()`, import block edit
(existing block, no block, aliased import), wire goldens for the three messages. Swift: one Undo restores the exact pre-generation
text, a reply for a changed buffer is dropped, decoding. Menus: update the exact context-menu vectors and the Code-menu transcript
in `MenuSpecTests` (`:104`, `:121`), action-id uniqueness, selector mapping, shortcut parsing and context-menu/menu-bar parity; `--selftest-generate` (caret in a
struct → Generate → text inserted → undo → file compiles).

## Stage 4a status (core)
Done in `core/internal/generate`, the three control messages and their wire goldens: constructor, accessors, `String()`, error type,
functional options, table-driven test, `main()`, HTTP handler and mock of an interface. Known limits, to revisit in 4b: the test
item creates `<file>_test.go` and refuses when it already exists (core does not see unsaved test buffers); the mock does not
flatten embedded interfaces (the UI sends the method set); `String()` and the other receivers are pointer receivers.

## Order and branch
## Branch stack (all plans)
Dependencies cannot be cut from `main` while earlier work is only on `develop`. Stack, squash-merging into `develop` in this order
after approval: (1) prerequisites; (2) Find Usages and (3) project templates, each cut from the merged prerequisites;
(4) Generate cut from the merged prerequisites and Find Usages, with (4a) core engine and wire, (4b) editor items, (4c) Design
Pattern submenu and dialog, (4d) Explorer folder items stacked in that order. This departs from "cut every branch from `main`" and
needs the owner's OK once.

 CHANGELOG, README (shortcut), mock gap file, report in `docs/changelog/`.

## Stages 4b to 4d status (macOS UI)
Done: Swift wire client and presentation state (`GobiModel/Generate*.swift`), ⌃N and the menu entries, the popup at the caret
built from `documentSymbolInfos`, the dialog with live preview, one-`apply` insertion with the request version and `RequestGate`,
file creation, Fill struct, Explorer folder items (core: `folder.go`) and Implement Interface… (core: `implement.go`), and
`--selftest-generate`.
- gopls finding: with `resolveSupport` alone gopls still answered Fill struct as a `gopls.apply_fix` command; the client must also
  declare `dataSupport` to get `data` for `codeAction/resolve`. Declaring resolve makes gopls send *every* lazily computed action
  without its edit, so Organize Imports and the Code Actions menu now resolve before applying (`CodeAction.resolveData`).
- Implement Interface… reads the interface from the same buffer (core parses it); an interface from another file or package is not
  offered. Getters and setters, constructor and the other struct items take the symbol model's field names and type text.
- Known limits: the symbol model gives no underlying basic type, so `String()` uses `%v` for a named string type; folder items do not
  see declarations in sibling files (a name clash shows up in the compiler); the dialog has no per-field tick for the struct items
  that insert at once.

