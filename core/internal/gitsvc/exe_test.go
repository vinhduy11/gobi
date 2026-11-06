package gitsvc

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func fakeGit(t *testing.T, marker string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "git")
	if err := os.WriteFile(path, []byte("#!/bin/sh\necho "+marker+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSessionsKeepTheirOwnGitExecutable(t *testing.T) {
	dir := t.TempDir()
	sessions := map[string]Git{"alpha": {Exe: fakeGit(t, "alpha")}, "beta": {Exe: fakeGit(t, "beta")}}
	var wg sync.WaitGroup
	for marker, session := range sessions {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 20 {
				out, err := session.run(dir, nil, "status")
				if err != nil || strings.TrimSpace(out) != marker {
					t.Errorf("%s session ran %q (%v)", marker, out, err)
					return
				}
			}
		}()
	}
	wg.Wait()
}
