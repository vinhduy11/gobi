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

func TestGitChannelStashListApplyPopDropAndAmend(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"AUTHOR", "COMMITTER"} {
		t.Setenv("GIT_"+name+"_NAME", "t")
		t.Setenv("GIT_"+name+"_EMAIL", "t@example.test")
	}
	git := func(args ...string) {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git("init", "-q", "-b", "main")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("a\n"), 0o644)
	git("add", ".")
	git("commit", "-q", "-m", "first")

	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	call := func(build func(w *wire.Writer)) map[int][]wire.Field { return gitCall(t, session, build) }
	kindOnly := func(kind uint64, number int) map[int][]wire.Field {
		return call(func(w *wire.Writer) {
			w.Uint(gitKind, kind)
			w.Uint(gitNumber, uint64(number))
		})
	}
	expect := func(r map[int][]wire.Field, kind uint64, what string) {
		t.Helper()
		if r[gitKind][0].Uint != kind {
			t.Fatalf("%s: reply = %v error=%v", what, r, r[gitError])
		}
	}

	os.WriteFile(filepath.Join(dir, "a.go"), []byte("work\n"), 0o644)
	expect(call(func(w *wire.Writer) { w.Uint(gitKind, gitStashRequest); w.String(gitText, "saved work") }), gitDoneReply, "stash")
	r := kindOnly(gitStashListRequest, 0)
	expect(r, gitListReply, "stash list")
	if len(r[gitEntry]) != 1 || !strings.HasPrefix(string(r[gitEntry][0].Bytes), "0\x1f") || !strings.Contains(string(r[gitEntry][0].Bytes), "saved work") {
		t.Fatalf("stash list = %v", r[gitEntry])
	}
	expect(kindOnly(gitStashApplyRequest, 0), gitDoneReply, "apply")
	git("checkout", "--", "a.go")
	expect(kindOnly(gitStashPopRequest, 0), gitDoneReply, "pop")
	expect(kindOnly(gitStashDropRequest, 0), gitErrorReply, "drop with nothing stashed")

	git("add", "a.go")
	expect(call(func(w *wire.Writer) {
		w.Uint(gitKind, gitCommitRequest)
		w.String(gitText, "reworded")
		w.Uint(gitFlag, 1)
	}), gitDoneReply, "amend")
	r = call(func(w *wire.Writer) { w.Uint(gitKind, gitLogRequest); w.Uint(gitNumber, 5) })
	if len(r[gitEntry]) != 1 || !strings.HasSuffix(string(r[gitEntry][0].Bytes), "reworded") {
		t.Errorf("log after amend = %v", r[gitEntry])
	}
}
