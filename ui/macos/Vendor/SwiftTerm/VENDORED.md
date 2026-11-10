# SwiftTerm, vendored

Base: SwiftTerm 1.5.1 (https://github.com/migueldeicaza/SwiftTerm), MIT licence (see `LICENSE`).

Only `Sources/SwiftTerm` is kept, without the iOS sources; `Package.swift` is ours (macOS only, one library target). Every change
from upstream is marked `GOBI` in the source and has a test in `Tests/TerminalForkTests`.

| Patch | File | Why |
|---|---|---|
| A move with no button is reported `CSI < 35;x;y M`, not `CSI < 32;x;y m` | `Terminal.swift` `sendEvent` | The old report is a release of the left button: programs that track the mouse (Claude Code) saw a click wherever the pointer passed. Also drops a stray `print` in the SGR pixel path. |
| SGR with a private marker or intermediate is ignored | `Terminal.swift` `cmdCharAttributes` | `CSI > 4 m` (modifyOtherKeys reset, sent by Claude Code) turned underline on for everything after it. |
| SGR sub-parameters (`4:3`, `38:2::r:g:b`, `58:...`) | `Terminal.swift` `cmdCharAttributesWithSubParameters` | The colons were read as semicolons: `4:3` also switched italic on. |
| `resetNormalBuffer` keeps `buffer` pointing at the new buffer | `Terminal.swift` | The terminal stayed on the replaced buffer, which no longer followed resizes: lines wrapped at the old width and added rows stayed black. |
| `Terminal.sendWheel` and an `open` `scrollWheel` that uses it | `Terminal.swift`, `Mac/MacTerminalView.swift` | A full-screen program gets the wheel as mouse reports, or as arrow keys on the alternate screen. Shift keeps the local scrollback. |

To take a newer upstream: copy its `Sources/SwiftTerm` over this one, then re-apply the table above (`rg -n GOBI Sources`) and run the
tests. Patches that upstream has fixed can be dropped together with their tests.
