# More project templates in New Project

## Spec
Pick a ready-made template when creating a project: command-line tool, library, HTTP service, gRPC service, message
consumer, scheduled job (and the existing workspace and empty module). Mock: New Project board (group "Service", Message
consumer selected).

## Today
`core/internal/project/templates.go` has `cli`, `library`, `http`, `empty`, `workspace` (placeholders `{{module}}`, `{{name}}`,
`{{pkg}}`, optional sample test). The dialog lists them from `TemplateCatalog` (`GobiModel/ProjectForm.swift`,
`GobiApp/NewProjectWindowController.swift`).

## Design
- **Stdlib-only, complete offline.** `project.Create` removes the new folder on any error (`project.go:156`), so a template must
  never need a download inside creation. v1 adds `consumer` and `job`; `http` stays.
  - `consumer`: a worker loop over a small `Source` interface (one method), `context` cancelled on SIGINT/SIGTERM, a handler
    that is easy to test, `sync.WaitGroup` for shutdown; sample test with a fake source. Kafka/MQTT adapters come later as
    separate templates.
  - `job`: one run or a ticker loop with `context`, exit code on failure.
- `grpc` (needs `google.golang.org/grpc`) and `cli-cobra` are **out of this plan**. They need a post-create dependency step that is a
  separate plan with its own request fields, lifecycle, cancellation, cleanup, result schema, UI retry and a fake downloader for tests.
  Sketch only: `project/new` gets an additive
  result field (new field number, never renumber; update `docs/architect/wire-protocol.md`, Go and Swift codecs and the golden
  wire tests). The UI shows "Created; dependencies not downloaded: <reason>" and does not treat it as a failure. Tests: timeout,
  DNS failure, proxy down, partial download.
- **Catalogue from core**: add a read-only control method `project/templates` returning, per template, a stable id, order, group,
  title, summary and availability (the "Will create" list keeps using `project/preview`). `TemplateCatalog` in `GobiModel/ProjectForm.swift`
  becomes the decoded result with the current list as the offline fallback. Tests: a Go wire golden for the method, a `GobiClient`
  decoding test, and an integration check in `--selftest-newproject` against a real gobid (a Swift test cannot see core).
  Update `docs/architect/wire-protocol.md`.

## Style
Generated code follows Effective Go where it applies (names, doc comments starting with the name, early return, small interfaces),
the Go errors guidance (`%w`) and `context` conventions. Tests: every template renders, then `gofmt -l` is empty,
`go vet ./...` and `go test ./...` pass in a temp module; an exact golden file per template.

## Order and branch
After the prerequisites; branch per the stack note in `generate.md`; CHANGELOG, README (template list), mock gap file, report in `docs/changelog/`.
Open question for the owner: which consumer kinds first (plain worker, Kafka, MQTT, RabbitMQ)? Default: plain worker.
