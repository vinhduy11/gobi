# Safety

- **Workspace trust**: an untrusted workspace is read-only plus gopls analysis. No toolchain downloads,
  `go generate`, builds, tests, cgo, `.gobi` profiles or tasks, terminals or debug launches until the user trusts it.
- **Secrets**: never in tracked files or logs. Keychain or a gitignored `.env`; redact in logs, DAP variables,
  terminal capture and crash reports.
- **Non-local targets**: profiles declare typed targets. Confirm before tests, migrations or scripts that touch a
  non-local target. The hard block applies only to Gobi-owned structured actions.
- **Sockets**: private 0700 directory, 0600 socket, peer-UID check, never unlink a socket that is not conclusively stale.
- Never run tests, migrations or scripts against a database, Redis, OpenSearch, Kafka or MQTT without printing the
  resolved targets and getting the user's go-ahead.
