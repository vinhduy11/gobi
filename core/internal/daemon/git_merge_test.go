//go:build unix

package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

func TestGitChannelMergeAndFetch(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"AUTHOR", "COMMITTER"} {
		t.Setenv("GIT_"+name+"_NAME", "t")
		t.Setenv("GIT_"+name+"_EMAIL", "t@example.test")
	}
	run := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	commit := func(file, message string) {
		os.WriteFile(filepath.Join(dir, file), []byte(file+"\n"), 0o644)
		run("add", ".")
		run("commit", "-q", "-m", message)
	}
	run("init", "-q", "-b", "main")
	commit("a.go", "first")
	run("switch", "-q", "-c", "topic")
	commit("t.go", "topic")
	run("switch", "-q", "main")
	commit("m.go", "main")

	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitMergeRequest); w.String(gitText, "topic") }); r[gitKind][0].Uint != gitDoneReply {
		t.Fatalf("merge reply = %v %v", r, r[gitError])
	}
	if _, err := os.Stat(filepath.Join(dir, "t.go")); err != nil {
		t.Error("t.go missing after merge")
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitMergeRequest); w.String(gitText, "missing") }); r[gitKind][0].Uint != gitErrorReply {
		t.Errorf("merging an unknown branch must be an error: %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitFetchRequest) }); r[gitKind][0].Uint != gitDoneReply {
		t.Errorf("fetch reply = %v %v", r, r[gitError])
	}
}

func TestGitChannelUsesTheHandshakeGitPath(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(t.TempDir(), "fakegit")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\necho fake git says no >&2\nexit 3\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true, Tool: fake})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitStatusRequest) })
	if r[gitKind][0].Uint != gitErrorReply || string(r[gitError][0].Bytes) == "" {
		t.Errorf("status through a failing git must be an error: %v", r)
	}
}

func TestLSPChannelStartsTheServerNamedInTheHandshake(t *testing.T) {
	socketPath, stop := startDaemon(t, map[string][]string{"go": {"/nonexistent/gopls"}})
	defer stop()
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "lsp", WorkspaceRoot: "/work/hello", Tool: fakeBinary})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if response := call(t, session, 1, "initialize", map[string]any{"capabilities": map[string]any{}}); response["error"] != nil {
		t.Fatalf("initialize through the chosen server: %s", response["error"])
	}
}

func TestToolAdmitRefusesAnUnusablePath(t *testing.T) {
	for _, channel := range []string{"git", "lsp"} {
		if reason := toolAdmit(ipc.Hello{Channel: channel, Tool: "relative/git"}); reason == "" {
			t.Errorf("%s: a relative path must be refused", channel)
		}
		if reason := toolAdmit(ipc.Hello{Channel: channel, Tool: "/nonexistent/tool"}); reason == "" {
			t.Errorf("%s: a missing file must be refused", channel)
		}
		if reason := toolAdmit(ipc.Hello{Channel: channel}); reason != "" {
			t.Errorf("%s: empty means the default: %s", channel, reason)
		}
	}
	if reason := toolAdmit(ipc.Hello{Channel: "pty", Tool: "/nonexistent/tool"}); reason != "" {
		t.Error("other channels ignore the field")
	}
}
