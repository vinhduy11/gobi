# Third-party packages

| Package | Where | Licence | Why |
|---|---|---|---|
| SwiftTerm 1.5.1 (`github.com/migueldeicaza/SwiftTerm`) | `ui/macos`, imported by `GobiApp` only | MIT | Terminal emulator view for the Terminal tab (escape sequences, colours, full-screen programs). Writing and testing an emulator is far larger than the rest of the tab. Pinned to an exact version. Version 1.9.0 and later depend on a package that has no stable release, which SwiftPM refuses, so 1.5.1 is used. It also pulls `swift-argument-parser` (Apache 2.0) for its own command-line tool, which Gobi does not link. |
| `github.com/creack/pty` v1.1.24 | `core/internal/pty` | MIT | Opens a pseudo-terminal and starts the shell on it. |

Rules: a new dependency needs a line here with its licence and the reason; the Swift `GobiModel`, `GobiClient` and `GobiEditor` layers import no third-party package.
