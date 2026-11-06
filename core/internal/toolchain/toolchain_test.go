package toolchain

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func fakeTool(t *testing.T, dir, name, versionOutput string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	script := "#!/bin/sh\necho '" + versionOutput + "'\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestFindPrefersGOBINOverPATH(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fakes")
	}
	gobinDir, pathDir := t.TempDir(), t.TempDir()
	want := fakeTool(t, gobinDir, "gopls", "v1")
	fakeTool(t, pathDir, "gopls", "v2")

	finder := Finder{Env: map[string]string{"GOBIN": gobinDir, "PATH": pathDir}}
	got, err := finder.Find("gopls")
	if err != nil || got != want {
		t.Fatalf("got %q, %v; want %q", got, err, want)
	}
}

func TestFindUsesGOPATHBinThenPATH(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fakes")
	}
	gopathDir, pathDir := t.TempDir(), t.TempDir()
	binDir := filepath.Join(gopathDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	want := fakeTool(t, binDir, "dlv", "v1")
	fakeTool(t, pathDir, "dlv", "v2")

	finder := Finder{Env: map[string]string{"GOPATH": gopathDir, "PATH": pathDir}}
	got, err := finder.Find("dlv")
	if err != nil || got != want {
		t.Fatalf("got %q, %v; want %q", got, err, want)
	}

	onlyPath := Finder{Env: map[string]string{"PATH": pathDir}}
	got, err = onlyPath.Find("dlv")
	if err != nil || filepath.Dir(got) != pathDir {
		t.Fatalf("PATH fallback: got %q, %v", got, err)
	}
}

func TestFindMissingTool(t *testing.T) {
	finder := Finder{Env: map[string]string{"PATH": t.TempDir()}}
	if _, err := finder.Find("gopls"); err == nil {
		t.Fatal("want error for missing tool")
	}
}

func TestCheckReportsVersionAndMissing(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script fakes")
	}
	binDir := t.TempDir()
	fakeTool(t, binDir, "go", "go version go1.26.5 darwin/arm64")
	finder := Finder{Env: map[string]string{"PATH": binDir}}

	reports := Check(finder, []Tool{
		{Name: "go", VersionArgs: []string{"version"}, Required: true},
		{Name: "gopls", VersionArgs: []string{"version"}, Required: true},
	})
	if len(reports) != 2 {
		t.Fatalf("got %d reports", len(reports))
	}
	if !reports[0].Found || !strings.Contains(reports[0].Version, "go1.26.5") {
		t.Fatalf("go report: %+v", reports[0])
	}
	if reports[1].Found {
		t.Fatalf("gopls should be missing: %+v", reports[1])
	}
	if !HasMissingRequired(reports) {
		t.Fatal("missing required tool must be flagged")
	}
	if HasMissingRequired(reports[:1]) {
		t.Fatal("found tool must not be flagged")
	}
}

func TestMissingOptionalToolIsNotFlagged(t *testing.T) {
	finder := Finder{Env: map[string]string{"PATH": t.TempDir()}}
	reports := Check(finder, []Tool{{Name: "dlv", VersionArgs: []string{"version"}}})
	if reports[0].Found || HasMissingRequired(reports) {
		t.Fatalf("optional missing tool: %+v", reports[0])
	}
}

func TestInstallCommandKnowsTheGoInstallableTools(t *testing.T) {
	args, ok := InstallArgs("gopls")
	if !ok || strings.Join(args, " ") != "install golang.org/x/tools/gopls@latest" {
		t.Errorf("gopls = %v %v", args, ok)
	}
	args, ok = InstallArgs("dlv")
	if !ok || strings.Join(args, " ") != "install github.com/go-delve/delve/cmd/dlv@latest" {
		t.Errorf("dlv = %v %v", args, ok)
	}
	if _, ok := InstallArgs("go"); ok {
		t.Error("go cannot be installed with go install")
	}
}

func TestHintTellsHowToGetATheToolsThatCannotBeAutoInstalled(t *testing.T) {
	for _, name := range []string{"go", "git"} {
		if Hint(name) == "" {
			t.Errorf("no hint for %s", name)
		}
	}
}

func TestInstallRunsGoInstallThroughTheFinder(t *testing.T) {
	dir := t.TempDir()
	record := filepath.Join(dir, "args.txt")
	script := "#!/bin/sh\necho \"$@\" > " + record + "\n"
	if err := os.WriteFile(filepath.Join(dir, "go"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Install(context.Background(), Finder{Env: map[string]string{"PATH": dir}}, "dlv"); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(record)
	if strings.TrimSpace(string(got)) != "install github.com/go-delve/delve/cmd/dlv@latest" {
		t.Errorf("go was run with %q", got)
	}
}

func TestInstallNeedsGo(t *testing.T) {
	err := Install(context.Background(), Finder{Env: map[string]string{"PATH": t.TempDir()}}, "dlv")
	if err == nil || !strings.Contains(err.Error(), "go") {
		t.Errorf("err = %v", err)
	}
	if err := Install(context.Background(), Finder{}, "go"); err == nil {
		t.Error("go itself must not be auto-installed")
	}
}
