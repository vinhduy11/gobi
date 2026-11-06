# Gobi wire protocol

Every connection to `gobid` uses the same framing (`Content-Length` header, then the payload; see `core/internal/rpc`).
What the payload holds depends on the channel.

| Channel | Payload |
|---|---|
| handshake (first message each way, every channel) | binary, protobuf wire format |
| `control` | binary, protobuf wire format |
| `lsp` | JSON-RPC, because gopls and the built-in language services speak it and the broker passes bytes through |
| `dap` | framed DAP JSON, one message per frame, passed through between the UI and `dlv dap` (see the debug channel below) |
| `pty`, `run`, `git`, later channels | binary |

## Encoding
The protobuf wire format, hand-coded in `core/internal/wire` and `ui/macos/Sources/GobiClient/Wire.swift`: a field is a
key (`number << 3 | type`) and a value; types used are 0 (varint) and 2 (length-delimited). Strings are UTF-8; an empty
string is left out; booleans are 0 or 1; nested messages are length-delimited. Receivers ignore field numbers they do not
know, so a newer peer can add fields. Never reuse or renumber a field. Any protobuf library can read these bytes, so a
`.proto` schema can replace the hand-coded layout later without changing the wire.

## Handshake
- Hello (client to server): 1 protocol (uint, now 1), 2 client version, 3 channel, 4 workspace root, 5 trusted (bool), 6 language, 7 Go folder, 8 shell, 9 tool: an absolute path to an executable that replaces the program the channel runs (git on the `git` channel, gopls on the `lsp` channel for Go); refused when relative or not executable; empty: the one on PATH.
- Reply (server to client): 1 ok (bool), 2 protocol (uint), 3 error (string, on refusal).
- A first message that is not valid binary (for example the old JSON hello) is refused with an error that says the handshake is binary.

## Control channel
- Request: 1 id (uint), 2 method (string), 3 params (message).
- Reply: 1 id (uint), 2 failure message (string, only on failure), 3 result (message).
- `project/new` params: 1 template, 2 name, 3 location, 4 module path, 5 go version, 6 git init (bool), 7 sample test (bool), 8 scaffold: README, .gitignore, .env.example (bool), 9 work dir (add the module to the go.work in that folder).
- `project/preview` params: as `project/new`; result: 1 root, 4 file (repeated, relative to the root). It writes nothing; the list is the one `project/new` would write.
- `project/templates` params: none; result: 1 template (repeated message, in dialog order: 1 id, 2 order (1-based), 3 group, 4 title, 5 summary, 6 available (bool)). Read-only; the ids are the values `project/new` takes in field 1. New fields get new numbers; none is renumbered.
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

## Run channel (`run`)
- Handshake: `workspace_root` is the folder the commands run in; `trusted` must be true (running a project runs its code), otherwise the handshake is refused with a message that says running code is off in Restricted Mode.
- Client to server: 1 kind (1 start, 2 stop). Start adds 2 command (`run`, `test`, `vet`, `build`), 3 package (repeated), 4 test filter (`go test -run`), 5 argument (repeated; `run` only, except that `build` accepts the single argument `-a` to rebuild everything), 6 environment file inside the project (empty: `.env` when present; `-`: none), 7 Go folder to use (absolute, holds `bin/go`; empty: the `go` on PATH), 8 environment entry `KEY=VALUE` from the active profile (repeated; names are plain identifiers, `DYLD_*` and `LD_*` are refused, at most 500 entries).
- Server to client: 1 kind (1 output, 2 test, 3 exit).
  - output: 2 data, 6 stream (1 stdout, 2 stderr).
  - test (from `go test -json`): 7 action (`run`, `pass`, `fail`, `skip`, `output`, ...), 8 package, 9 test name (empty for a whole package), 10 elapsed milliseconds, 11 output text. The same output text is also sent as an output message, so an Output panel shows what `go test` would print.
  - exit: 12 exit code (128 plus the signal when stopped), 13 message. A refused request ends with exit code 125 and a message; the connection stays usable.
- One run at a time per connection. Package patterns, the filter and arguments are checked before anything runs (a pattern cannot start with `-`; `run` takes exactly one package).

## Git channel (`git`)
- Handshake: `workspace_root` is the folder asked about; `trusted` must be true (git runs hooks and filters the repository names), otherwise the handshake is refused.
- Client to server: 1 kind (1 status, 2 diff, 3 branches, 4 checkout, 5 stage, 6 unstage, 7 commit, 8 log, 9 changed lines, 10 discard (paths in field 6), 11 push, 12 pull, 13 merge (text: the branch; a merge commit is made without an editor, and a conflict aborts the merge with an error that names the files), 14 fetch (all remotes; a repository with no remote answers done); push publishes a branch without an upstream to the first remote, pull is fast-forward only, git never asks for a password on a terminal); 5 text argument (a path, a branch name or a commit message), 6 path (repeated), 7 flag (diff: staged; checkout: create), 8 number (log: how many).
- Server to client: 1 kind (1 status, 2 error, 3 text, 4 branches, 5 log, 6 lines, 7 done). Status: 2 branch (empty outside a repository), 3 entry (repeated: one digit for the mark, one digit for the stage state (0 none, 1 staged, 2 unstaged, 3 both), then the path relative to the repository root; a trailing slash is a whole folder), 5 ahead, 6 behind. Marks: 1 modified, 2 added, 3 deleted, 4 renamed, 5 untracked, 6 ignored, 7 conflict. Error: 4 message. Text: 8 text (a diff). Branches: 3 entry (repeated: `1` or `0` for the current branch, then the name). Log: 3 entry (repeated: hash, author, when and subject separated by 0x1f). Lines: 3 entry (repeated: `kind start count`; kind 1 added, 2 modified, 3 deleted). Done: no fields.
- More client kinds, all answered `done` or an error unless noted: 15 tag (text: name; lightweight tag on HEAD), 16 reset (text: `soft`, `mixed` or `hard`; field 9 second text: revision, empty means HEAD; hard discards working tree changes, the UI asks first), 17 stash (text: message; includes untracked files; errors when there is nothing to stash), 18 unstash (pop the newest), 19 abort merge, 20 rebase (text: branch to rebase onto; on a conflict the rebase stays in progress and the error says so), 21 abort rebase, 22 continue rebase, 23 skip rebase, 24 patch (answers a text reply with `git diff HEAD --binary`; untracked files are not in it), 25 apply patch (text: absolute path of a patch file), 26 continue revert, 27 abort revert, 28 continue cherry-pick, 29 abort cherry-pick, 30 remotes (answers a list reply), 31 add remote (text: name, field 9: address), 32 remove remote (text: name), 33 worktrees (answers a list reply), 34 add worktree (text: absolute folder, field 9: branch, flag: create the branch), 35 remove worktree (text: absolute folder). Field 9 is a second text argument. No editor ever opens (`GIT_EDITOR=true`).
- Amend and stashes: 7 commit with flag (field 7) set amends the last commit with the staged files and the text as its message. 36 stash list (answered with a list reply, entries are the stash index and its message separated by 0x1f, newest first), 37 stash apply, 38 stash pop, 39 stash drop (field 8 number: the index n of stash@{n}; apply and pop bring the changes back, pop and drop remove the entry; a missing index is an error).
- New server kind 8 list: 3 entry (repeated; remotes: name and address, worktrees: folder, branch (empty when detached) and head, separated by 0x1f). Status gains 7 operation: `merge`, `rebase`, `revert` or `cherry-pick` while one is waiting in the repository (from the git dir's MERGE_HEAD, rebase-merge/rebase-apply, REVERT_HEAD, CHERRY_PICK_HEAD), absent otherwise.
- The handshake `tool` (git program) belongs to that session only; sessions with different git programs never affect each other. Remote addresses and git error text have the password of a `scheme://user:password@host` address removed (`user@host` and `git@host:path` are unchanged).
- One answer per request, in order. Paths must stay inside the repository and cannot look like options; branch names are limited to letters, digits and `._/-`.

## Debug channel (`dap`)
- Handshake: `workspace_root` is the project folder; `trusted` must be true (debugging runs the program), otherwise refused. If `dlv` is not installed the handshake is refused with a message that names it.
- Payloads are Debug Adapter Protocol JSON messages, one per frame, in both directions; gobid starts `dlv dap` in the project folder and passes them through unchanged. Delve writes the program's stdout and stderr to its own output instead of DAP events, so gobid adds `output` events (`category` stdout or stderr) for them.

## Control channel additions
- `tools/check`: no params; result field 1 repeated, one message per tool: 1 name, 2 required, 3 found, 4 version, 5 path, 6 problem, 7 installable by Gobi, 8 hint.
- `tools/install`: 1 tool name; runs `go install` for gopls or dlv; fails for anything else with a message.
- `toolchain/available`: no params; result field 1 repeated, Go versions that can be installed, newest first.
- `toolchain/install`: 1 version (`1.25.10`); downloads Go into `~/sdk` with `golang.org/dl`. Versions are digits and dots only.
- `profile/load`: 1 absolute path of a `.pprof` file, 2 sample index as text (empty: the profile default). Result: 1 sample type (repeated: 1 type, 2 unit), 2 chosen index, 3 total, 4 duration in ns, 5 node (repeated: 1 id, 2 parent id (0 for the root), 3 name, 4 flat, 5 cum, 6 file, 7 line; a parent always comes before its children), 6 top row (repeated: 1 name, 2 flat, 3 cum). The tree keeps only branches that cost at least a thousandth of the total.
- `profile/lines`: 1 absolute path, 2 sample index as text (empty: default), 3 function name. Result: 1 source file, 2 line row (repeated: 1 line, 2 flat, 3 cum), ordered by line, 3 line of the function declaration (0 when the profile does not say).
- `profile/diff`: 1 base path, 2 other path (both absolute), 3 sample type name (empty: the base default). Result: 1 type name, 2 unit, 3 base total, 4 other total, 5 row (repeated, largest absolute flat change first, at most 200: 1 name, 2 base flat, 3 other flat, 4 base cum, 5 other cum). The client computes the signed deltas.
- `profile/capture`: 1 address (`localhost`, `127.0.0.1` or `::1` with a port), 2 kind (`cpu`, `heap`, `allocs`, `goroutine`, `mutex`, `block`), 3 seconds as text (cpu only, up to 120), 4 absolute output path ending in `.pprof`. The file must not exist yet: it is created exclusively and an existing file is an error ("already exists"); the UI uses timestamped names.

## Terminal additions
- Handshake field 8 `shell`: an absolute path that `/etc/shells` lists; anything else is refused. Empty starts the login shell.
- Control method `terminal/shells`: no params; result field 1 repeated (the listed shells that exist), 2 login shell.
- `daemon/status`: no params; result 1 pid, 2 Go runtime version, 3 log level, 4 start time (unix seconds).
- `daemon/loglevel`: 1 level (`debug`, `info`, `warn`, `error`); refused for any other text.
- `daemon/stop`: no params; replies, then gobid shuts down. The app starts a new one on its next connection.
- `search/files`: 1 query, 2 regex, 3 case sensitive, 4 whole word, 5 replacement, 6 has replacement, 7 include glob (repeated), 8 most results (0: 2000), 9 absolute project folder. Result: 1 match (repeated: 1 path relative to the folder, 2 line (0-based), 3 start and 4 end (UTF-16 columns of the whole line), 5 text (the line, shortened around the match when over 400 bytes), 6 column where the text starts, 7 replacement text with `$1` style groups expanded for regular expressions), 2 files with matches, 3 files skipped, 4 truncated. Symbolic links are skipped, so a link cannot lead outside the folder.

## Generate (control channel)
Methods `generate/list`, `generate/preview` and `generate/render` share one request layout; the layout is also in
`core/internal/generate/codec.go`. Request: 1 path, 2 package, 3 caret line, 4 caret column (0-based), 5 kind (`struct`, `interface`, `func`, `file`, `empty`), 6 symbol name, 7 field (repeated: 1 name, 2 type text, 3 underlying basic type, may be empty), 8 source (the live buffer), 9 buffer version, 10 item id (`constructor`, `accessors`, `string`, `error-type`, `options`, `test`, `main`, `http-handler`, `mock`; unused by list), 11 ticked field name (repeated; empty means the item's default), 12 name asked by the dialog (error type, handler), 13 method (repeated: 1 name, 2 parameter (as 7), 3 result type (repeated)), 14 function parameter (as 7), 15 function result type (repeated), 16 receiver type name, 17 module Go version (`1.23` or `go1.23.4`; empty = unknown), 18 parameter answer (repeated: 1 key, 2 value (repeated); a blank answer means the pattern's default), 19 target (`current`, the default, or `file`: write `<pattern>.go` in the folder of the open file, or in the folder itself when `path` is a folder).
- `generate/list` result: 1 version, 2 item (repeated: 1 id, 2 title, 3 detail, 4 needs name, 5 needs fields, 6 group (`creational`, `structural`, `behavioral`; design patterns only), 7 parameter (repeated: 1 key, 2 label, 3 default (repeated), 4 kind (`type`, `names`, `signature`, `fields`, `typeexpr`), 5 list). Design patterns are offered for caret kinds `file` and `empty` only (not inside a function, struct or interface); they carry ids `factory-method` … `visitor`.
- `generate/preview` and `generate/render` result: 1 version, 2 text (the formatted code to insert), 3 import path (repeated), 4 edit (repeated: 1 start line, 2 start character, 3 end line, 4 end character, 5 new text; 0-based, UTF-16 columns, ranges refer to the original buffer and do not overlap), 5 file (repeated: 1 path, 2 content; files to create). Preview carries no edits or files.
- Every result echoes the request's version (field 1) so the UI drops a reply for a buffer that changed. The code in the edits is final: formatted with `go/format`, imports added through `go/ast`, so the UI applies the whole set in one undo group and does not call LSP formatting. A buffer that does not parse, or an item that does not apply to the context, fails the request.
