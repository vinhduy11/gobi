# Gobi wire protocol

Every connection to `gobid` uses the same framing (`Content-Length` header, then the payload; see `core/internal/rpc`).
What the payload holds depends on the channel.

| Channel | Payload |
|---|---|
| handshake (first message each way, every channel) | binary, protobuf wire format |
| `control` | binary, protobuf wire format |
| `lsp` | JSON-RPC, because gopls and the built-in language services speak it and the broker passes bytes through |
| `dap`, `pty`, later channels | binary from the start (dlv's DAP is JSON, so `dap` will be a translated binary channel) |

## Encoding
The protobuf wire format, hand-coded in `core/internal/wire` and `ui/macos/Sources/GobiClient/Wire.swift`: a field is a
key (`number << 3 | type`) and a value; types used are 0 (varint) and 2 (length-delimited). Strings are UTF-8; an empty
string is left out; booleans are 0 or 1; nested messages are length-delimited. Receivers ignore field numbers they do not
know, so a newer peer can add fields. Never reuse or renumber a field. Any protobuf library can read these bytes, so a
`.proto` schema can replace the hand-coded layout later without changing the wire.

## Handshake
- Hello (client to server): 1 protocol (uint, now 1), 2 client version, 3 channel, 4 workspace root, 5 trusted (bool), 6 language.
- Reply (server to client): 1 ok (bool), 2 protocol (uint), 3 error (string, on refusal).
- A first message that is not valid binary (for example the old JSON hello) is refused with an error that says the handshake is binary.

## Control channel
- Request: 1 id (uint), 2 method (string), 3 params (message).
- Reply: 1 id (uint), 2 failure message (string, only on failure), 3 result (message).
- `project/new` params: 1 template, 2 name, 3 location, 4 module path, 5 go version, 6 git init (bool), 7 sample test (bool), 8 scaffold: README, .gitignore, .env.example (bool), 9 work dir (add the module to the go.work in that folder).
- `project/preview` params: as `project/new`; result: 1 root, 4 file (repeated, relative to the root). It writes nothing; the list is the one `project/new` would write.
- `project/clone` params: 1 url, 2 location, 3 folder name.
- `project/open` params: 1 path. `project/import` params: 1 path, 2 module path.
- Result of all four: 1 root, 2 kind (`workspace`, `module`, `folder`), 3 module path.
- Requests on one connection are answered in order.

## Tests that guard the layout
Golden bytes for the protobuf examples, the hello, the reply and a control request are asserted in both Go
(`internal/wire`, `internal/ipc`, `internal/daemon`) and Swift (`WireTests`). `FuzzParse` covers the Go parser.

## Terminal channel (`pty`)
- Handshake: `workspace_root` is the folder the shell starts in; `trusted` must be true, otherwise the handshake is refused with a message that says terminals are off in Restricted Mode.
- Client to server: 1 kind (1 input, 2 resize), 2 data (the bytes typed), 3 columns, 4 rows.
- Server to client: 1 kind (1 output, 3 exit), 2 data (terminal output, or an error text with exit code 127 when the shell could not start), 5 exit code (128 plus the signal number when the shell was killed).
- The shell is the daemon user's login shell (`$SHELL`, else `/bin/sh`) with `TERM=xterm-256color`. Closing the connection hangs it up. One shell per connection.
