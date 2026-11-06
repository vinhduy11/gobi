package search

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSymlinksLeavingTheWorkspaceAreNotSearched(t *testing.T) {
	outside := tree(t, map[string]string{"secret.txt": "needle outside\n"})
	root := tree(t, map[string]string{"in.txt": "needle inside\n"})
	if err := os.Symlink(filepath.Join(outside, "secret.txt"), filepath.Join(root, "abs.txt")); err != nil {
		t.Fatal(err)
	}
	rel, _ := filepath.Rel(root, filepath.Join(outside, "secret.txt"))
	if err := os.Symlink(rel, filepath.Join(root, "rel.txt")); err != nil {
		t.Fatal(err)
	}
	assertOnlyInside := func(mode string) {
		r := find(t, root, Options{Query: "needle"})
		if len(r.Matches) != 1 || r.Matches[0].Path != "in.txt" {
			t.Errorf("%s: matches = %+v", mode, r.Matches)
		}
	}
	assertOnlyInside("walk")
	for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}} {
		if err := runGit(root, args...); err != nil {
			t.Skip("git unavailable")
		}
	}
	assertOnlyInside("git")
}
