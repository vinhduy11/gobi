package gitsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// twoBranches returns a repo on main with a branch "topic" that has one commit main does not. With conflict, both change line 2.
func twoBranches(t *testing.T, conflict bool) string {
	t.Helper()
	for _, name := range []string{"AUTHOR", "COMMITTER"} {
		t.Setenv("GIT_"+name+"_NAME", "t")
		t.Setenv("GIT_"+name+"_EMAIL", "t@example.test")
	}
	dir := repo(t)
	git(t, dir, "switch", "-q", "-c", "topic")
	if conflict {
		write(t, dir, "a.go", "line1\ntopic\nline3\nline4\nline5\n")
	} else {
		write(t, dir, "t.go", "topic\n")
	}
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "topic work")
	git(t, dir, "switch", "-q", "main")
	write(t, dir, "m.go", "main\n")
	if conflict {
		write(t, dir, "a.go", "line1\nmain\nline3\nline4\nline5\n")
	}
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "main work")
	return dir
}

func TestMergeCreatesAMergeCommitWithoutAnEditor(t *testing.T) {
	dir := twoBranches(t, false)
	if err := testGit.Merge(dir, "topic"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "t.go")); err != nil {
		t.Error("the merged file is missing")
	}
	if out, _ := testGit.run(dir, nil, "rev-list", "--parents", "-n", "1", "HEAD"); len(strings.Fields(out)) != 3 {
		t.Errorf("HEAD must be a merge commit, got %q", out)
	}
}

func TestMergeConflictIsAbortedWithAClearError(t *testing.T) {
	dir := twoBranches(t, true)
	err := testGit.Merge(dir, "topic")
	if err == nil || !strings.Contains(err.Error(), "conflict") || !strings.Contains(err.Error(), "aborted") {
		t.Fatalf("err = %v, want a conflict error saying the merge was aborted", err)
	}
	if st, _ := testGit.Status(dir); len(st.Files) != 0 {
		t.Errorf("the tree must be clean after the abort: %+v", st.Files)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "a.go")); strings.Contains(string(got), "<<<<") {
		t.Errorf("a.go still has conflict markers: %q", got)
	}
}

func TestMergeRefusesABadBranchName(t *testing.T) {
	for _, name := range []string{"", "-x", "a..b", "x y"} {
		if err := testGit.Merge(repo(t), name); err == nil {
			t.Errorf("%q must be refused", name)
		}
	}
}

func TestMergeUnknownBranchFails(t *testing.T) {
	if err := testGit.Merge(repo(t), "nope"); err == nil {
		t.Error("an unknown branch must fail")
	}
}

func TestFetchUpdatesRemoteBranches(t *testing.T) {
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	first := repo(t)
	git(t, first, "remote", "add", "origin", remote)
	git(t, first, "push", "-q", "-u", "origin", "main")
	second := t.TempDir()
	git(t, second, "clone", "-q", remote, ".")
	write(t, second, "n.go", "n\n")
	git(t, second, "add", ".")
	git(t, second, "commit", "-q", "-m", "n")
	git(t, second, "push", "-q")
	if err := testGit.Fetch(first); err != nil {
		t.Fatal(err)
	}
	if st, _ := testGit.Status(first); st.Behind != 1 {
		t.Errorf("behind = %d after fetch, want 1", st.Behind)
	}
}

func TestFetchWithoutARemoteIsQuiet(t *testing.T) {
	if err := testGit.Fetch(repo(t)); err != nil {
		t.Errorf("a repository with no remote has nothing to fetch: %v", err)
	}
}

func TestExeChangesWhatRuns(t *testing.T) {
	dir := repo(t)
	broken := Git{Exe: "/nonexistent/git"}
	if _, err := broken.Status(dir); err == nil {
		t.Error("status must use the configured executable")
	}
	if _, err := broken.run(dir, nil, "status"); err == nil {
		t.Error("run must use the configured executable")
	}
	if _, err := testGit.Status(dir); err != nil {
		t.Errorf("empty means git on PATH: %v", err)
	}
}
