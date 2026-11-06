package gitsvc

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.email=t@example.test", "-c", "user.name=t"}, args...)...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func write(t *testing.T, dir, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStatusOfARepository(t *testing.T) {
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	write(t, dir, "kept.go", "package a\n")
	write(t, dir, "changed.go", "package a\n")
	write(t, dir, ".gitignore", "ignored.txt\n")
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "first")
	write(t, dir, "changed.go", "package a // edited\n")
	write(t, dir, "new.go", "package a\n")
	write(t, dir, "staged.go", "package a\n")
	write(t, dir, "ignored.txt", "x")
	git(t, dir, "add", "staged.go")

	got, err := testGit.Status(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got.Branch != "main" {
		t.Errorf("branch = %q, want main", got.Branch)
	}
	want := map[string]Mark{"changed.go": Modified, "new.go": Untracked, "staged.go": Added, "ignored.txt": Ignored}
	have := map[string]Mark{}
	for _, f := range got.Files {
		have[f.Path] = f.Mark
	}
	for path, mark := range want {
		if have[path] != mark {
			t.Errorf("%s = %v, want %v (all: %v)", path, have[path], mark, have)
		}
	}
	if _, listed := have["kept.go"]; listed {
		t.Error("an unchanged file must not be listed")
	}
}

func TestStatusOutsideARepositoryIsEmpty(t *testing.T) {
	got, err := testGit.Status(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if got.Branch != "" || len(got.Files) != 0 {
		t.Errorf("got %+v, want empty", got)
	}
}

func TestStatusRejectsRelativeDir(t *testing.T) {
	if _, err := testGit.Status("relative"); err == nil {
		t.Error("relative directory must be refused")
	}
}

func repo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	write(t, dir, "a.go", "line1\nline2\nline3\nline4\nline5\n")
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "first commit")
	return dir
}

func TestStatusReportsAheadAndBehindCounts(t *testing.T) {
	dir := repo(t)
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	git(t, dir, "remote", "add", "origin", remote)
	git(t, dir, "push", "-q", "-u", "origin", "main")
	write(t, dir, "b.go", "x\n")
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "second")
	got, err := testGit.Status(dir)
	if err != nil || got.Ahead != 1 || got.Behind != 0 {
		t.Errorf("got %+v, %v", got, err)
	}
}

func TestDiffOfAModifiedStagedAndUntrackedFile(t *testing.T) {
	dir := repo(t)
	write(t, dir, "a.go", "line1\nCHANGED\nline3\nline4\nline5\n")
	diff, err := testGit.Diff(dir, "a.go", false)
	if err != nil || !strings.Contains(diff, "-line2") || !strings.Contains(diff, "+CHANGED") {
		t.Errorf("unstaged diff = %q, %v", diff, err)
	}
	if staged, _ := testGit.Diff(dir, "a.go", true); staged != "" {
		t.Errorf("nothing is staged yet: %q", staged)
	}
	git(t, dir, "add", "a.go")
	if staged, _ := testGit.Diff(dir, "a.go", true); !strings.Contains(staged, "+CHANGED") {
		t.Errorf("staged diff = %q", staged)
	}
	write(t, dir, "new.go", "brand new\n")
	fresh, err := testGit.Diff(dir, "new.go", false)
	if err != nil || !strings.Contains(fresh, "+brand new") {
		t.Errorf("untracked diff = %q, %v", fresh, err)
	}
}

func TestPathsAreKeptInsideTheRepository(t *testing.T) {
	dir := repo(t)
	for _, bad := range []string{"../x", "/etc/passwd", "-p", "a/../../b"} {
		if _, err := testGit.Diff(dir, bad, false); err == nil {
			t.Errorf("%q should be refused", bad)
		}
		if err := testGit.Stage(dir, []string{bad}); err == nil {
			t.Errorf("staging %q should be refused", bad)
		}
	}
}

func TestStageUnstageAndCommit(t *testing.T) {
	dir := repo(t)
	write(t, dir, "a.go", "changed\n")
	write(t, dir, "b.go", "second\n")
	if err := testGit.Stage(dir, []string{"a.go"}); err != nil {
		t.Fatal(err)
	}
	status, _ := testGit.Status(dir)
	marks := map[string]Mark{}
	for _, f := range status.Files {
		marks[f.Path] = f.Mark
	}
	if !status.hasStaged("a.go") || marks["b.go"] != Untracked {
		t.Fatalf("after staging: %+v", status.Files)
	}
	if err := testGit.Unstage(dir, []string{"a.go"}); err != nil {
		t.Fatal(err)
	}
	if s, _ := testGit.Status(dir); s.hasStaged("a.go") {
		t.Error("a.go is still staged")
	}
	testGit.Stage(dir, []string{"a.go"})
	if err := testGit.Commit(dir, "change a", "t@example.test", "t"); err != nil {
		t.Fatal(err)
	}
	commits, err := testGit.Log(dir, 5)
	if err != nil || len(commits) != 2 || commits[0].Subject != "change a" || commits[1].Subject != "first commit" || len(commits[0].Hash) < 7 {
		t.Errorf("log = %+v, %v", commits, err)
	}
	if err := testGit.Commit(dir, "   ", "t@example.test", "t"); err == nil {
		t.Error("an empty message must be refused")
	}
	if err := testGit.Commit(dir, "nothing staged", "t@example.test", "t"); err == nil {
		t.Error("committing with nothing staged must fail")
	}
}

func TestBranchesAndCheckout(t *testing.T) {
	dir := repo(t)
	if err := testGit.Checkout(dir, "feature/x", true); err != nil {
		t.Fatal(err)
	}
	branches, err := testGit.Branches(dir)
	if err != nil || len(branches) != 2 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	current := ""
	for _, b := range branches {
		if b.Current {
			current = b.Name
		}
	}
	if current != "feature/x" {
		t.Errorf("current = %q", current)
	}
	names := []string{}
	for _, b := range branches {
		names = append(names, b.Name)
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "feature/x,main" {
		t.Errorf("names = %v (a branch that is not current must keep its first letter)", names)
	}
	if err := testGit.Checkout(dir, "main", false); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"-x", "a b", "../x", "", "a..b", "x;rm"} {
		if err := testGit.Checkout(dir, bad, true); err == nil {
			t.Errorf("branch name %q should be refused", bad)
		}
	}
}

func TestChangedLinesClassifiesAddedModifiedAndDeleted(t *testing.T) {
	dir := repo(t)
	// line2 modified, line4 deleted, two lines added at the end
	write(t, dir, "a.go", "line1\nline2 edited\nline3\nline5\nnew1\nnew2\n")
	changes, err := testGit.ChangedLines(dir, "a.go")
	if err != nil {
		t.Fatal(err)
	}
	want := []LineChange{{Start: 2, Count: 1, Kind: LinesModified}, {Start: 3, Count: 0, Kind: LinesDeleted}, {Start: 5, Count: 2, Kind: LinesAdded}}
	if len(changes) != len(want) {
		t.Fatalf("changes = %+v", changes)
	}
	for i := range want {
		if changes[i] != want[i] {
			t.Errorf("change %d = %+v, want %+v", i, changes[i], want[i])
		}
	}
	write(t, dir, "fresh.go", "a\nb\nc\n")
	fresh, _ := testGit.ChangedLines(dir, "fresh.go")
	if len(fresh) != 1 || fresh[0] != (LineChange{Start: 1, Count: 3, Kind: LinesAdded}) {
		t.Errorf("untracked file = %+v", fresh)
	}
	if none, _ := testGit.ChangedLines(dir, "missing.go"); len(none) != 0 {
		t.Errorf("a missing file has no changes: %+v", none)
	}
}

func TestDiscardRestoresTrackedFilesAndRemovesUntracked(t *testing.T) {
	dir := repo(t)
	write(t, dir, "a.go", "package a\n")
	write(t, dir, "b.go", "package b\n")
	git(t, dir, "add", ".")
	git(t, dir, "commit", "-q", "-m", "two files")
	write(t, dir, "a.go", "package a // edited\n")
	write(t, dir, "b.go", "package b // staged edit\n")
	git(t, dir, "add", "b.go")
	write(t, dir, "new.go", "package n\n")

	if err := testGit.Discard(dir, []string{"a.go", "b.go", "new.go"}); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"a.go": "package a\n", "b.go": "package b\n"} {
		got, _ := os.ReadFile(filepath.Join(dir, name))
		if string(got) != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "new.go")); !os.IsNotExist(err) {
		t.Errorf("the untracked file should be gone, stat error: %v", err)
	}
	status, err := testGit.Status(dir)
	if err != nil || len(status.Files) != 0 {
		t.Errorf("status after discard = %+v, %v", status, err)
	}
	if err := testGit.Discard(dir, []string{"../outside"}); err == nil {
		t.Error("a path outside the repository must be refused")
	}
}

func TestPushAndPullWithARemote(t *testing.T) {
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	first := repo(t)
	git(t, first, "remote", "add", "origin", remote)
	write(t, first, "a.go", "package a\n")
	git(t, first, "add", ".")
	git(t, first, "commit", "-q", "-m", "one")
	if err := testGit.Push(first); err != nil {
		t.Fatalf("first push (sets the upstream): %v", err)
	}
	second := t.TempDir()
	git(t, second, "clone", "-q", remote, ".")
	write(t, second, "b.go", "package b\n")
	git(t, second, "add", ".")
	git(t, second, "commit", "-q", "-m", "two")
	if err := testGit.Push(second); err != nil {
		t.Fatal(err)
	}
	if err := testGit.Pull(first); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(first, "b.go")); err != nil {
		t.Errorf("pull should bring b.go: %v", err)
	}
	// Diverged history is refused instead of merged behind the person's back.
	write(t, first, "c.go", "package c\n")
	git(t, first, "add", ".")
	git(t, first, "commit", "-q", "-m", "three")
	write(t, second, "d.go", "package d\n")
	git(t, second, "add", ".")
	git(t, second, "commit", "-q", "-m", "four")
	if err := testGit.Push(second); err != nil {
		t.Fatal(err)
	}
	if err := testGit.Pull(first); err == nil {
		t.Error("pull of a diverged branch must fail")
	}
}
