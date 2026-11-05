# Layers

## Reference: three software layers (same on every platform)

Diagram: `docs/diagram/gobi-software-layers.html` (source `docs/diagram/gobi-software-layers.architecture.json`). It names no
platform. Calls go downward only: UI to application to core.

| Software layer | Job | Today's stack layers |
|---|---|---|
| UI | Draw, take input, host the platform toolkit's windows, views and panels. No protocol, no project rules. | Swift: `GobiEditor`, `GobiApp` |
| Application | What the app knows and decides, with no toolkit import: editor model (lines, syntax, find, edits), project state (recents, trust, tabs, form checks), and the client that talks to the core. The only code that talks to the core. | Swift: `GobiModel`, `GobiClient` |
| Core | Everything that owns a tool or a process: transport and channels, language services, project services, run services (terminal, toolchain, later debug). Knows nothing about any UI. | Go: all of `core` (foundation, services, transport, composition, entry) |

Each platform's stack (the two sections below, and the Windows and Linux ones later) must fit this table: a stack layer
belongs to exactly one software layer, and a software layer never reaches upward.

## The stack layers

Diagram: `docs/diagram/gobi-layers.html` (source `docs/diagram/gobi-layers.architecture.json`). It also shows the planned
Windows and Linux UIs, marked as next version: they are not built yet.

A layer imports only layers below it. Both sides check this automatically, so the rule cannot slip.

## UI side (`ui/macos`, one Swift package; each platform repeats these four layers)

| Layer | Module | Holds | May import |
|---|---|---|---|
| 1 | `GobiModel` | Logic with no platform dependency: line index, syntax tokenizer and index, tab strip, project and form checks, wire format codec, frame decoder | nothing |
| 2 | `GobiClient` | Talking to gobid: unix socket, handshake, control and LSP clients | Foundation, Darwin, `GobiModel` |
| 3 | `GobiEditor` | The AppKit editor view: text view, gutter, find bar, highlighter | AppKit, `GobiModel`, `GobiClient` |
| 4 | `GobiApp` | Windows, menus, dialogs, explorer, tabs | everything below |

Checked by `ui/macos/scripts/check-layers.sh`, which `scripts/test.sh` runs first. `gobi-probe`, `gobi-bench` and
`gobi-check` are tools that sit at layer 4.

## Core side (`core`, Go)

| Layer | Packages | May import |
|---|---|---|
| 0 foundation | `wire`, `rpc`, `textlines` | no internal package |
| 1 services | `lsp`, `langsvc`, `project`, `pty`, `toolchain` | foundation only (services never import each other) |
| 2 transport | `ipc` | foundation only |
| 3 composition | `daemon` | any lower layer |
| 4 entry | `cmd/gobid` | any lower layer |

Checked by `core/internal/layers`. A new package fails that test until it is given a layer, so the choice is made when the
package is added.

## Why these shapes
- Services do not know about sockets, and the transport does not know about services. `daemon` is the only place that
  connects them, so either side can change alone, and a service can be reused by another front end (a CLI, tests).
- `GobiModel` has no imports, so its logic ports to another language by reading it, and runs in tests without a UI.
- A new platform adds `ui/<platform>` and rebuilds layers 1 to 4 there; the core stays as it is, apart from the transport
  and pty files for that platform (see `cross-platform.md`).
