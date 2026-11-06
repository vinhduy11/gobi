package gitsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStashListApplyPopDrop(t *testing.T) {
	identity(t)
	dir := repo(t)
	write(t, dir, "a.go", "one\n")
	if err := testGit.Stash(dir, "first work"); err != nil {
		t.Fatal(err)
	}
	write(t, dir, "a.go", "two\n")
	if err := testGit.Stash(dir, "second work"); err != nil {
		t.Fatal(err)
	}
	list, err := testGit.StashList(dir)
	if err != nil || len(list) != 2 || list[0].Index != 0 || list[1].Index != 1 || !strings.Contains(list[0].Message, "second work") || !strings.Contains(list[1].Message, "first work") {
		t.Fatalf("list = %+v, %v", list, err)
	}
	if err := testGit.StashApply(dir, 1); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "a.go")); string(data) != "one\n" {
		t.Errorf("apply brought %q", data)
	}
	if l, _ := testGit.StashList(dir); len(l) != 2 {
		t.Error("apply keeps the stash")
	}
	if err := testGit.Reset(dir, "hard", "HEAD"); err != nil {
		t.Fatal(err)
	}
	if err := testGit.StashDrop(dir, 0); err != nil {
		t.Fatal(err)
	}
	if l, _ := testGit.StashList(dir); len(l) != 1 || !strings.Contains(l[0].Message, "first work") {
		t.Errorf("after drop = %+v", l)
	}
	if err := testGit.StashPop(dir, 0); err != nil {
		t.Fatal(err)
	}
	if l, _ := testGit.StashList(dir); len(l) != 0 {
		t.Error("pop removes the stash")
	}
	if testGit.StashApply(dir, 0) == nil || testGit.StashDrop(dir, 5) == nil || testGit.StashPop(dir, -1) == nil {
		t.Error("a missing or negative index must be an error")
	}
}

func TestAmendReplacesTheLastCommit(t *testing.T) {
	dir := repo(t)
	write(t, dir, "a.go", "changed\n")
	testGit.Stage(dir, []string{"a.go"})
	if err := testGit.CommitAmend(dir, "better first", "t@example.test", "t"); err != nil {
		t.Fatal(err)
	}
	commits, _ := testGit.Log(dir, 5)
	if len(commits) != 1 || commits[0].Subject != "better first" {
		t.Errorf("log = %+v", commits)
	}
	if out, _ := testGit.run(dir, nil, "show", "--stat", "--format=", "HEAD"); !strings.Contains(out, "a.go") {
		t.Errorf("the staged change must join the amended commit: %q", out)
	}
	if testGit.CommitAmend(dir, "  ", "", "") == nil {
		t.Error("an empty message must be refused")
	}
}
