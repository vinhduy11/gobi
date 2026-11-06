//go:build unix

package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeGoRoot makes a folder whose bin/go prints its arguments and the toolchain environment instead of building anything.
func fakeGoRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\necho \"args=$@\"\necho \"GOROOT=$GOROOT\"\necho \"GOTOOLCHAIN=$GOTOOLCHAIN\"\necho \"PATHHEAD=${PATH%%:*}\"\n"
	if err := os.WriteFile(filepath.Join(root, "bin", "go"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestRunUsesTheChosenGoRoot(t *testing.T) {
	root := fakeGoRoot(t)
	dir := writeModule(t, map[string]string{"main.go": "package main\n\nfunc main() {}\n"})
	run, err := Start(context.Background(), Request{Kind: KindVet, Dir: dir, GoRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	for _, event := range collect(t, run) {
		out.Write(event.Data)
	}
	text := out.String()
	for _, want := range []string{"args=vet ./...", "GOROOT=" + root, "GOTOOLCHAIN=local", "PATHHEAD=" + filepath.Join(root, "bin")} {
		if !strings.Contains(text, want) {
			t.Errorf("output lacks %q:\n%s", want, text)
		}
	}
}

func TestGoRootMustBeAUsableToolchain(t *testing.T) {
	dir := writeModule(t, map[string]string{})
	for name, root := range map[string]string{"relative": "go1.25", "missing": filepath.Join(t.TempDir(), "nope"), "no bin/go": t.TempDir()} {
		if _, err := Start(context.Background(), Request{Kind: KindVet, Dir: dir, GoRoot: root}); err == nil {
			t.Errorf("%s: expected a refusal", name)
		}
	}
}
