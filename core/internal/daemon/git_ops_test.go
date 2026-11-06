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

func TestGitChannelOperations(t *testing.T) {
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
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "-q", "-m", "first")

	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "git", WorkspaceRoot: dir, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	call := func(kind uint64, text, text2 string, flag bool) map[int][]wire.Field {
		return gitCall(t, session, func(w *wire.Writer) {
			w.Uint(gitKind, kind)
			if text != "" {
				w.String(gitText, text)
			}
			if text2 != "" {
				w.String(gitText2, text2)
			}
			if flag {
				w.Uint(gitFlag, 1)
			}
		})
	}
	expect := func(r map[int][]wire.Field, kind uint64, what string) {
		t.Helper()
		if r[gitKind][0].Uint != kind {
			t.Fatalf("%s: reply = %v error=%v", what, r, r[gitError])
		}
	}

	expect(call(gitTagRequest, "v1", "", false), gitDoneReply, "tag")
	expect(call(gitTagRequest, "bad name", "", false), gitErrorReply, "bad tag")

	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := call(gitPatchRequest, "", "", false)
	expect(r, gitTextReply, "patch")
	if !strings.Contains(string(r[gitBody][0].Bytes), "+changed") {
		t.Errorf("patch body = %q", r[gitBody][0].Bytes)
	}
	expect(call(gitStashRequest, "saved", "", false), gitDoneReply, "stash")
	expect(call(gitUnstashRequest, "", "", false), gitDoneReply, "unstash")
	expect(call(gitResetRequest, "hard", "HEAD", false), gitDoneReply, "reset")

	status := call(gitStatusRequest, "", "", false)
	expect(status, gitStatusReply, "status")
	if len(status[gitOperation]) != 0 && string(status[gitOperation][0].Bytes) != "" {
		t.Errorf("no operation expected: %q", status[gitOperation][0].Bytes)
	}

	expect(call(gitAddRemoteRequest, "origin", "https://example.test/x.git", false), gitDoneReply, "add remote")
	r = call(gitRemotesRequest, "", "", false)
	expect(r, gitListReply, "remotes")
	if len(r[gitEntry]) != 1 || string(r[gitEntry][0].Bytes) != "origin\x1fhttps://example.test/x.git" {
		t.Errorf("remotes = %v", r[gitEntry])
	}
	expect(call(gitRemoveRemoteRequest, "origin", "", false), gitDoneReply, "remove remote")

	wt := filepath.Join(t.TempDir(), "wt")
	expect(call(gitAddWorktreeRequest, wt, "feature", true), gitDoneReply, "add worktree")
	r = call(gitWorktreesRequest, "", "", false)
	expect(r, gitListReply, "worktrees")
	if len(r[gitEntry]) != 2 {
		t.Errorf("worktrees = %v", r[gitEntry])
	}
	expect(call(gitRemoveWorktreeRequest, wt, "", false), gitDoneReply, "remove worktree")

	// merge in progress is reported by status and abortable
	git("switch", "-q", "-c", "topic")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("topic\n"), 0o644)
	git("commit", "-q", "-am", "topic")
	git("switch", "-q", "main")
	os.WriteFile(filepath.Join(dir, "a.go"), []byte("main\n"), 0o644)
	git("commit", "-q", "-am", "main")
	exec.Command("git", "-C", dir, "merge", "--no-edit", "topic").Run()
	status = call(gitStatusRequest, "", "", false)
	if len(status[gitOperation]) == 0 || string(status[gitOperation][0].Bytes) != "merge" {
		t.Fatalf("status operation = %v", status[gitOperation])
	}
	expect(call(gitAbortMergeRequest, "", "", false), gitDoneReply, "abort merge")

	git("switch", "-q", "topic")
	expect(call(gitRebaseRequest, "main", "", false), gitErrorReply, "conflicting rebase")
	expect(call(gitAbortRebaseRequest, "", "", false), gitDoneReply, "abort rebase")
	expect(call(gitContinueRevertRequest, "", "", false), gitErrorReply, "continue revert without one")
	expect(call(gitAbortCherryPickRequest, "", "", false), gitErrorReply, "abort cherry-pick without one")
}
