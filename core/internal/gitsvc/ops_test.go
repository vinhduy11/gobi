package gitsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func identity(t *testing.T) {
	t.Helper()
	for _, name := range []string{"AUTHOR", "COMMITTER"} {
		t.Setenv("GIT_"+name+"_NAME", "t")
		t.Setenv("GIT_"+name+"_EMAIL", "t@example.test")
	}
}

func TestTagMakesATagAndRefusesBadNames(t *testing.T) {
	dir := repo(t)
	if err := testGit.Tag(dir, "v1.0.0"); err != nil {
		t.Fatal(err)
	}
	if out, _ := testGit.run(dir, nil, "tag", "--list"); strings.TrimSpace(out) != "v1.0.0" {
		t.Errorf("tags = %q", out)
	}
	if testGit.Tag(dir, "bad name") == nil || testGit.Tag(dir, "-d") == nil {
		t.Error("bad tag names must be refused")
	}
}

func TestDiscardRemovesAnUntrackedFolder(t *testing.T) {
	dir := repo(t)
	if err := os.MkdirAll(filepath.Join(dir, "newdir"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, dir, "newdir/x.go", "package x\n")
	if err := testGit.Discard(dir, []string{"newdir/"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "newdir")); err == nil {
		t.Error("the untracked folder must be deleted")
	}
}

func TestResetModes(t *testing.T) {
	dir := repo(t)
	write(t, dir, "b.go", "b\n")
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "second")
	if err := testGit.Reset(dir, "soft", "HEAD~1"); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); len(st.Files) != 1 || !st.Files[0].Staged {
		t.Errorf("soft keeps the change staged: %+v", st.Files)
	}
	if err := testGit.Reset(dir, "mixed", "HEAD"); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); len(st.Files) != 1 || st.Files[0].Staged {
		t.Errorf("mixed unstages: %+v", st.Files)
	}
	git(t, dir, "add", ".")
	if err := testGit.Reset(dir, "hard", "HEAD"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "b.go")); err == nil {
		t.Error("hard removes the change from the disk")
	}
	if testGit.Reset(dir, "bogus", "HEAD") == nil || testGit.Reset(dir, "hard", "--oops") == nil {
		t.Error("unknown mode and option-like target must be refused")
	}
}

func TestStashAndUnstash(t *testing.T) {
	identity(t)
	dir := repo(t)
	write(t, dir, "a.go", "changed\n")
	write(t, dir, "new.go", "new\n")
	if err := testGit.Stash(dir, "my work"); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); len(st.Files) != 0 {
		t.Errorf("working tree must be clean after stash: %+v", st.Files)
	}
	if out, _ := testGit.run(dir, nil, "stash", "list"); !strings.Contains(out, "my work") {
		t.Errorf("stash list = %q", out)
	}
	if err := testGit.Unstash(dir); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "a.go")); string(data) != "changed\n" {
		t.Error("unstash must bring the edit back")
	}
	if _, err := os.Stat(filepath.Join(dir, "new.go")); err != nil {
		t.Error("untracked file must come back")
	}
	if testGit.Unstash(dir) == nil {
		t.Error("unstash with nothing stashed must be an error")
	}
}

func TestStashWithNothingToSaveIsAnError(t *testing.T) {
	identity(t)
	if err := testGit.Stash(repo(t), "x"); err == nil {
		t.Error("nothing to stash must be an error")
	}
}

func TestAbortMergeAndOperationState(t *testing.T) {
	identity(t)
	dir := twoBranches(t, true)
	if _, err := testGit.run(dir, nil, "merge", "--no-edit", "topic"); err == nil {
		t.Fatal("expected a conflict")
	}
	if st, _ := testGit.Status(dir); st.Operation != "merge" {
		t.Errorf("operation = %q, want merge", st.Operation)
	}
	if err := testGit.AbortMerge(dir); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" || len(st.Files) != 0 {
		t.Errorf("after abort: %+v", st)
	}
}

func TestRebaseLeavesConflictInProgressAndContinueSkipAbort(t *testing.T) {
	identity(t)
	dir := twoBranches(t, true)
	git(t, dir, "switch", "-q", "topic")
	err := testGit.Rebase(dir, "main")
	if err == nil || !strings.Contains(err.Error(), "in progress") {
		t.Fatalf("rebase conflict must report in progress, got %v", err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "rebase" {
		t.Fatalf("operation = %q", st.Operation)
	}
	if err := testGit.AbortRebase(dir); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" {
		t.Error("abort must end the rebase")
	}
	_ = testGit.Rebase(dir, "main")
	write(t, dir, "a.go", "resolved\n")
	git(t, dir, "add", "a.go")
	if err := testGit.ContinueRebase(dir); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" {
		t.Error("continue must finish the rebase")
	}
	git(t, dir, "reset", "-q", "--hard", "ORIG_HEAD")
	_ = testGit.Rebase(dir, "main")
	if err := testGit.SkipRebase(dir); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" {
		t.Error("skip must finish a one-commit rebase")
	}
	if testGit.Rebase(dir, "--evil") == nil {
		t.Error("option-like branch must be refused")
	}
}

func TestRebaseCleanReplays(t *testing.T) {
	identity(t)
	dir := twoBranches(t, false)
	git(t, dir, "switch", "-q", "topic")
	if err := testGit.Rebase(dir, "main"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "m.go")); err != nil {
		t.Error("topic must now contain main's file")
	}
}

func TestPatchRoundTrip(t *testing.T) {
	dir := repo(t)
	write(t, dir, "a.go", "line1\nCHANGED\nline3\nline4\nline5\n")
	patch, err := testGit.Patch(dir)
	if err != nil || !strings.Contains(patch, "+CHANGED") {
		t.Fatalf("patch = %q, %v", patch, err)
	}
	file := filepath.Join(t.TempDir(), "x.patch")
	if err := os.WriteFile(file, []byte(patch), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "checkout", "--", "a.go")
	if err := testGit.ApplyPatch(dir, file); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "a.go")); !strings.Contains(string(data), "CHANGED") {
		t.Error("patch not applied")
	}
	if testGit.ApplyPatch(dir, "relative.patch") == nil || testGit.ApplyPatch(dir, filepath.Join(t.TempDir(), "missing")) == nil {
		t.Error("relative or missing patch file must be refused")
	}
}

func TestCherryPickAndRevertStates(t *testing.T) {
	identity(t)
	dir := twoBranches(t, true)
	topic, _ := testGit.run(dir, nil, "rev-parse", "topic")
	if _, err := testGit.run(dir, nil, "cherry-pick", strings.TrimSpace(topic)); err == nil {
		t.Fatal("expected conflict")
	}
	if st, _ := testGit.Status(dir); st.Operation != "cherry-pick" {
		t.Fatalf("operation = %q", st.Operation)
	}
	if err := testGit.AbortSequence(dir, "cherry-pick"); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" {
		t.Error("abort cherry-pick")
	}
	// Reverting the first commit's content after main rewrote a.go conflicts.
	if _, err := testGit.run(dir, nil, "revert", "--no-edit", "HEAD~1"); err == nil {
		t.Skip("revert did not conflict")
	}
	if st, _ := testGit.Status(dir); st.Operation != "revert" {
		t.Fatalf("operation = %q", st.Operation)
	}
	write(t, dir, "a.go", "fixed\n")
	git(t, dir, "add", "-A")
	if err := testGit.ContinueSequence(dir, "revert"); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(dir); st.Operation != "" {
		t.Error("continue revert")
	}
	if testGit.AbortSequence(dir, "bogus") == nil {
		t.Error("unknown sequence must be refused")
	}
}

func TestRemotes(t *testing.T) {
	dir := repo(t)
	if err := testGit.AddRemote(dir, "origin", "https://example.test/x.git"); err != nil {
		t.Fatal(err)
	}
	list, err := testGit.Remotes(dir)
	if err != nil || len(list) != 1 || list[0].Name != "origin" || list[0].URL != "https://example.test/x.git" {
		t.Fatalf("remotes = %+v, %v", list, err)
	}
	if testGit.AddRemote(dir, "bad name", "u") == nil || testGit.AddRemote(dir, "ok", "") == nil || testGit.AddRemote(dir, "-x", "u") == nil {
		t.Error("bad remote input must be refused")
	}
	if err := testGit.RemoveRemote(dir, "origin"); err != nil {
		t.Fatal(err)
	}
	if list, _ := testGit.Remotes(dir); len(list) != 0 {
		t.Error("remote not removed")
	}
}

func TestWorktrees(t *testing.T) {
	dir := repo(t)
	path := filepath.Join(t.TempDir(), "wt")
	if err := testGit.AddWorktree(dir, path, "feature", true); err != nil {
		t.Fatal(err)
	}
	list, err := testGit.Worktrees(dir)
	if err != nil || len(list) != 2 {
		t.Fatalf("worktrees = %+v, %v", list, err)
	}
	found := false
	for _, w := range list {
		if w.Branch == "feature" {
			found = true
		}
	}
	if !found {
		t.Errorf("feature worktree missing: %+v", list)
	}
	if testGit.AddWorktree(dir, "relative", "x", true) == nil || testGit.AddWorktree(dir, path+"2", "-x", true) == nil {
		t.Error("bad worktree input must be refused")
	}
	if err := testGit.RemoveWorktree(dir, path); err != nil {
		t.Fatal(err)
	}
	if list, _ := testGit.Worktrees(dir); len(list) != 1 {
		t.Errorf("worktree not removed: %+v", list)
	}
}
