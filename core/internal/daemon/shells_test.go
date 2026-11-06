//go:build unix

package daemon

import (
	"os"
	"path/filepath"
	"testing"

	"gobi/core/internal/ipc"
)

func TestListedShellsComeFromTheShellsFile(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "myshell")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "shells")
	text := "# comment\n\n" + real + "\n/does/not/exist\nrelative/shell\n" + real + "\n"
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	got := listedShells(file)
	if len(got) != 1 || got[0] != real {
		t.Errorf("listed = %v, want only %s (comments, duplicates, missing and relative entries are dropped)", got, real)
	}
	if listedShells(filepath.Join(dir, "none")) != nil {
		t.Error("a missing shells file lists nothing")
	}
}

func TestShellAdmitOnlyAcceptsListedShells(t *testing.T) {
	dir := t.TempDir()
	shell := filepath.Join(dir, "okshell")
	os.WriteFile(shell, []byte("#!/bin/sh\n"), 0o755)
	file := filepath.Join(dir, "shells")
	os.WriteFile(file, []byte(shell+"\n"), 0o644)
	cases := map[string]struct {
		hello ipc.Hello
		ok    bool
	}{
		"default":        {ipc.Hello{Channel: "pty", Trusted: true}, true},
		"listed":         {ipc.Hello{Channel: "pty", Trusted: true, Shell: shell}, true},
		"not listed":     {ipc.Hello{Channel: "pty", Trusted: true, Shell: "/bin/evil"}, false},
		"other channel":  {ipc.Hello{Channel: "lsp", Shell: "/bin/evil"}, true},
		"relative shell": {ipc.Hello{Channel: "pty", Trusted: true, Shell: "sh"}, false},
	}
	for name, c := range cases {
		if reason := shellAdmit(c.hello, file); (reason == "") != c.ok {
			t.Errorf("%s: reason = %q", name, reason)
		}
	}
}
