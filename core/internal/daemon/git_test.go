//go:build unix

package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

func TestGitChannelReportsBranchAndMarks(t *testing.T) {
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q", "-b", "trunk"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git: %v %s", err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "new.go"), []byte("package a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	var request wire.Writer
	request.Uint(gitKind, gitStatusRequest)
	if err := session.Writer.Write(request.Bytes()); err != nil {
		t.Fatal(err)
	}
	payload, err := session.Reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	fields, err := wire.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	var branch string
	var entries []string
	for _, f := range fields {
		switch f.Number {
		case gitBranch:
			branch = string(f.Bytes)
		case gitEntry:
			entries = append(entries, string(f.Bytes))
		}
	}
	if branch != "trunk" {
		t.Errorf("branch = %q", branch)
	}
	if len(entries) != 1 || !strings.HasSuffix(entries[0], "new.go") || entries[0][0] != '5' || entries[0][1] != '0' { // 5 = Untracked, 0 = not staged
		t.Errorf("entries = %q", entries)
	}
}

func TestGitChannelIsOffInRestrictedMode(t *testing.T) {
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	if _, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: t.TempDir(), Trusted: false}); err == nil {
		t.Fatal("the git channel must be refused for an untrusted workspace")
	}
}

func gitCall(t *testing.T, session *ipc.Session, build func(*wire.Writer)) map[int][]wire.Field {
	t.Helper()
	var request wire.Writer
	build(&request)
	if err := session.Writer.Write(request.Bytes()); err != nil {
		t.Fatal(err)
	}
	payload, err := session.Reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	fields, err := wire.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	byNumber := map[int][]wire.Field{}
	for _, f := range fields {
		byNumber[f.Number] = append(byNumber[f.Number], f)
	}
	return byNumber
}

func TestGitChannelStageCommitLogDiffBranchesAndLines(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-c", "user.email=t@example.test", "-c", "user.name=t"}, args...)...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("one\ntwo\n"), 0o644)
	run("add", ".")
	run("commit", "-q", "-m", "first")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("one\nTWO\n"), 0o644)

	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitDiffRequest); w.String(gitText, "a.go") }); !strings.Contains(string(r[gitBody][0].Bytes), "+TWO") {
		t.Errorf("diff reply = %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitLinesRequest); w.String(gitText, "a.go") }); len(r[gitEntry]) != 1 || string(r[gitEntry][0].Bytes) != "2 2 1" {
		t.Errorf("lines reply = %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitStageRequest); w.String(gitPaths, "a.go") }); r[gitKind][0].Uint != gitDoneReply {
		t.Errorf("stage reply = %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitStatusRequest) }); string(r[gitEntry][0].Bytes) != "11a.go" {
		t.Errorf("status entry = %q", r[gitEntry][0].Bytes)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitCommitRequest); w.String(gitText, "edit two") }); r[gitKind][0].Uint != gitDoneReply {
		t.Errorf("commit reply = %v %v", r, r[gitError])
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitLogRequest); w.Uint(gitNumber, 5) }); len(r[gitEntry]) != 2 || !strings.HasSuffix(string(r[gitEntry][0].Bytes), "edit two") {
		t.Errorf("log reply = %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) {
		w.Uint(gitKind, gitCheckoutRequest)
		w.String(gitText, "topic")
		w.Bool(gitFlag, true)
	}); r[gitKind][0].Uint != gitDoneReply {
		t.Errorf("checkout reply = %v %v", r, r[gitError])
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitBranchesRequest) }); len(r[gitEntry]) != 2 {
		t.Errorf("branches reply = %v", r)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitDiffRequest); w.String(gitText, "../x") }); r[gitKind][0].Uint != gitErrorReply {
		t.Errorf("a path outside the repository must be an error: %v", r)
	}
}

func TestGitChannelDiscardPushAndPull(t *testing.T) {
	remote := t.TempDir()
	dir := t.TempDir()
	run := func(where string, args ...string) {
		cmd := exec.Command("git", append([]string{"-c", "user.email=t@example.test", "-c", "user.name=t"}, args...)...)
		cmd.Dir = where
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	run(remote, "init", "-q", "--bare", "-b", "main")
	run(dir, "init", "-q", "-b", "main")
	run(dir, "remote", "add", "origin", remote)
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("one\n"), 0o644)
	run(dir, "add", ".")
	run(dir, "commit", "-q", "-m", "first")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("edited\n"), 0o644)

	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitDiscardRequest); w.String(gitPaths, "a.go") }); r[gitKind][0].Uint != gitDoneReply {
		t.Fatalf("discard reply = %v %v", r, r[gitError])
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "a.go")); string(got) != "one\n" {
		t.Errorf("a.go after discard = %q", got)
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitPushRequest) }); r[gitKind][0].Uint != gitDoneReply {
		t.Fatalf("push reply = %v %v", r, r[gitError])
	}
	if r := gitCall(t, session, func(w *wire.Writer) { w.Uint(gitKind, gitPullRequest) }); r[gitKind][0].Uint != gitDoneReply {
		t.Errorf("pull reply = %v %v", r, r[gitError])
	}
}
