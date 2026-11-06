//go:build unix

package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gobi/core/internal/ipc"
)

func TestGoEnvPutsTheChosenGoFirst(t *testing.T) {
	base := []string{"HOME=/h", "PATH=/usr/bin:/bin", "GOROOT=/old", "GOTOOLCHAIN=auto"}
	got := goEnv("/sdk/go1.25.10", base)
	want := map[string]string{"GOROOT": "/sdk/go1.25.10", "GOTOOLCHAIN": "local", "PATH": "/sdk/go1.25.10/bin:/usr/bin:/bin"}
	seen := map[string]string{}
	for _, entry := range got {
		key, value, _ := strings.Cut(entry, "=")
		seen[key] = value // later entries win, as for a real process
	}
	for key, value := range want {
		if seen[key] != value {
			t.Errorf("%s = %q, want %q", key, seen[key], value)
		}
	}
	if seen["HOME"] != "/h" {
		t.Error("other variables must be kept")
	}
}

func TestGoAdmitChecksTheChosenGo(t *testing.T) {
	good := t.TempDir()
	if err := os.MkdirAll(filepath.Join(good, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(good, "bin", "go"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cases := map[string]struct {
		hello ipc.Hello
		ok    bool
	}{
		"none":       {ipc.Hello{Channel: "lsp"}, true},
		"valid":      {ipc.Hello{Channel: "lsp", GoRoot: good}, true},
		"relative":   {ipc.Hello{Channel: "lsp", GoRoot: "go1.25"}, false},
		"no bin/go":  {ipc.Hello{Channel: "lsp", GoRoot: t.TempDir()}, false},
		"other chan": {ipc.Hello{Channel: "git", GoRoot: "junk"}, true},
	}
	for name, c := range cases {
		if reason := goAdmit(c.hello); (reason == "") != c.ok {
			t.Errorf("%s: reason = %q", name, reason)
		}
	}
}
