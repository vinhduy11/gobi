# Third-party dependencies

Each dependency is reviewed before it is added. Reviewed: licence read from the module's own `LICENSE`, purpose,
and whether the standard library could do the job.

| Module | Version | Licence | Used for | Why not the standard library |
|---|---|---|---|---|
| `golang.org/x/sys` | v0.49.0 | BSD 3-Clause (The Go Authors) | `flock`, peer credentials (`LOCAL_PEERCRED`, `SO_PEERCRED`) in `internal/ipc` | `syscall` lacks the peer-credential calls and is frozen |
| `github.com/yuin/goldmark` | v1.8.7 | MIT | Markdown to HTML in `internal/langsvc` | A CommonMark and GFM renderer is not in the standard library; writing one is not worth the risk |

Not yet reviewed, planned for later slices: `creack/pty` (terminal), `google/pprof` (profiles), SwiftTerm (UI terminal).
