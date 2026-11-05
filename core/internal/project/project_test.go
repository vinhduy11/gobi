package project

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestValidateName(t *testing.T) {
	tests := map[string]struct {
		name    string
		wantErr bool
	}{
		"plain":             {"hello", false},
		"with dash and dot": {"my-app.v2", false},
		"empty":             {"", true},
		"slash":             {"a/b", true},
		"parent":            {"..", true},
		"leading dot":       {".hidden", true},
		"leading dash":      {"-rf", true},
		"space":             {"my app", true},
		"backslash":         {`a\b`, true},
		"too long":          {strings.Repeat("a", 101), true},
	}
	for label, test := range tests {
		t.Run(label, func(t *testing.T) {
			if err := ValidateName(test.name); (err != nil) != test.wantErr {
				t.Fatalf("ValidateName(%q) error = %v, wantErr %v", test.name, err, test.wantErr)
			}
		})
	}
}

func TestModulePathFromRemote(t *testing.T) {
	tests := map[string]string{
		"https://github.com/acme/widget.git": "github.com/acme/widget",
		"https://github.com/acme/widget":     "github.com/acme/widget",
		"git@github.com:acme/widget.git":     "github.com/acme/widget",
		"ssh://git@git.example.com/team/svc": "git.example.com/team/svc",
		"":                                   "",
		"not a url":                          "",
	}
	for remote, want := range tests {
		if got := ModulePathFromRemote(remote); got != want {
			t.Errorf("ModulePathFromRemote(%q) = %q, want %q", remote, got, want)
		}
	}
}

func TestCloneURLIsChecked(t *testing.T) {
	good := []string{"https://github.com/acme/widget.git", "git@github.com:acme/widget.git", "ssh://git@host/team/svc.git"}
	bad := []string{"", "-oProxyCommand=evil", "ext::sh -c evil", "--upload-pack=evil", "file:///etc", "ftp://host/x", "/local/path"}
	for _, url := range good {
		if err := ValidateCloneURL(url); err != nil {
			t.Errorf("ValidateCloneURL(%q) = %v, want ok", url, err)
		}
	}
	for _, url := range bad {
		if err := ValidateCloneURL(url); err == nil {
			t.Errorf("ValidateCloneURL(%q) accepted a URL that must be refused", url)
		}
	}
}

func TestTemplatesRenderTheModuleAndName(t *testing.T) {
	for _, kind := range []string{TemplateCLI, TemplateLibrary, TemplateHTTP, TemplateEmpty} {
		files, err := Render(kind, "example.com/acme/widget", "widget", true)
		if err != nil {
			t.Fatalf("Render(%q): %v", kind, err)
		}
		for path, content := range files {
			if filepath.IsAbs(path) || strings.Contains(path, "..") {
				t.Errorf("%s: template path %q escapes the project", kind, path)
			}
			if strings.Contains(content, "{{") {
				t.Errorf("%s: %s still has a placeholder: %q", kind, path, content)
			}
		}
	}
	files, _ := Render(TemplateCLI, "example.com/acme/widget", "widget", true)
	if _, ok := files["main.go"]; !ok {
		t.Errorf("cli template has no main.go: %v", keys(files))
	}
	files, _ = Render(TemplateLibrary, "example.com/acme/widget", "widget", true)
	if !strings.Contains(files["widget.go"], "package widget") {
		t.Errorf("library template should declare package widget: %q", files["widget.go"])
	}
	if _, err := Render("nope", "m", "n", true); err == nil {
		t.Error("an unknown template must be an error")
	}
}

func TestPackageNameFromProjectName(t *testing.T) {
	tests := map[string]string{"widget": "widget", "my-app": "myapp", "My.App2": "myapp2", "123go": "p123go"}
	for name, want := range tests {
		if got := packageName(name); got != want {
			t.Errorf("packageName(%q) = %q, want %q", name, got, want)
		}
	}
}

func requireTool(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s is not installed", name)
	}
}

func TestCreateWritesAModuleThatBuilds(t *testing.T) {
	requireTool(t, "go")
	location := t.TempDir()
	created, err := Create(NewRequest{Template: TemplateCLI, Name: "widget", Location: location, ModulePath: "example.com/acme/widget"})
	if err != nil {
		t.Fatal(err)
	}
	if created.Root != filepath.Join(location, "widget") || created.Kind != KindModule {
		t.Fatalf("unexpected result %+v", created)
	}
	build := exec.Command("go", "build", "./...")
	build.Dir = created.Root
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("the generated project does not build: %v\n%s", err, output)
	}
}

func TestCreateRefusesANonEmptyDestination(t *testing.T) {
	requireTool(t, "go")
	location := t.TempDir()
	target := filepath.Join(location, "widget")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "keep.txt"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Create(NewRequest{Template: TemplateEmpty, Name: "widget", Location: location, ModulePath: "example.com/widget"}); err == nil {
		t.Fatal("Create must not write into a folder that already has files")
	}
	if content, _ := os.ReadFile(filepath.Join(target, "keep.txt")); string(content) != "mine" {
		t.Fatal("the existing file was touched")
	}
}

func TestCreateWithGitInitUsesMaster(t *testing.T) {
	requireTool(t, "go")
	requireTool(t, "git")
	created, err := Create(NewRequest{Template: TemplateEmpty, Name: "repo", Location: t.TempDir(), ModulePath: "example.com/repo", GitInit: true, Scaffold: true})
	if err != nil {
		t.Fatal(err)
	}
	head, err := os.ReadFile(filepath.Join(created.Root, ".git", "HEAD"))
	if err != nil || !strings.Contains(string(head), "refs/heads/master") {
		t.Fatalf("git init should start on master, HEAD = %q (%v)", head, err)
	}
	ignore, err := os.ReadFile(filepath.Join(created.Root, ".gitignore"))
	if err != nil || !strings.Contains(string(ignore), ".env") {
		t.Fatalf(".gitignore should keep .env out of git: %q (%v)", ignore, err)
	}
}

func TestCreateWorkspaceHasAGoWorkFile(t *testing.T) {
	requireTool(t, "go")
	created, err := Create(NewRequest{Template: TemplateWorkspace, Name: "ws", Location: t.TempDir(), ModulePath: "example.com/ws"})
	if err != nil {
		t.Fatal(err)
	}
	if created.Kind != KindWorkspace {
		t.Fatalf("kind = %q, want workspace", created.Kind)
	}
	if _, err := os.Stat(filepath.Join(created.Root, "go.work")); err != nil {
		t.Fatal(err)
	}
}

func TestInspectFindsTheKindAndModule(t *testing.T) {
	dir := t.TempDir()
	if got := Inspect(dir); got.Kind != KindFolder {
		t.Fatalf("empty folder kind = %q", got.Kind)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/x\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := Inspect(dir)
	if got.Kind != KindModule || got.ModulePath != "example.com/x" {
		t.Fatalf("Inspect = %+v", got)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.work"), []byte("go 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := Inspect(dir); got.Kind != KindWorkspace {
		t.Fatalf("go.work should win, got %q", got.Kind)
	}
}

func TestImportCreatesTheModuleFromTheFolder(t *testing.T) {
	requireTool(t, "go")
	dir := filepath.Join(t.TempDir(), "legacy")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\n\nfunc main() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := Import(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	if got.Kind != KindModule || got.ModulePath != "legacy" {
		t.Fatalf("Import = %+v (module path should default to the folder name)", got)
	}
	if _, err := Import(dir, ""); err == nil {
		t.Fatal("importing a folder that already has go.mod must be refused")
	}
}

func keys(files map[string]string) []string {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	return names
}

func TestCloneCopiesARepositoryAndRefusesAnExistingFolder(t *testing.T) {
	requireTool(t, "git")
	source := t.TempDir()
	for _, args := range [][]string{{"init", "--quiet"}, {"-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "--quiet", "-m", "first"}} {
		command := exec.Command("git", args...)
		command.Dir = source
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
	}
	location := t.TempDir()
	request := CloneRequest{URL: source, Location: location, Name: "copy"}
	info, err := cloneInto(context.Background(), request, "file")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(info.Root, ".git")); err != nil {
		t.Fatalf("clone has no .git: %v", err)
	}
	if _, err := cloneInto(context.Background(), request, "file"); err == nil {
		t.Fatal("cloning into a folder that already has files must be refused")
	}
}

func TestCloneRefusesAnUnsafeURLBeforeRunningGit(t *testing.T) {
	if _, err := Clone(context.Background(), CloneRequest{URL: "ext::sh -c touch /tmp/pwned", Location: t.TempDir()}); err == nil {
		t.Fatal("an ext:: URL must be refused")
	}
}

func TestSampleTestIsOptionalAndTheProjectsStillPass(t *testing.T) {
	requireTool(t, "go")
	for _, template := range []string{TemplateCLI, TemplateLibrary, TemplateHTTP} {
		t.Run(template, func(t *testing.T) {
			without, err := Create(NewRequest{Template: template, Name: "plain", Location: t.TempDir(), ModulePath: "example.com/plain"})
			if err != nil {
				t.Fatal(err)
			}
			if names := testFilesIn(t, without.Root); len(names) != 0 {
				t.Fatalf("without the option there must be no test file, found %v", names)
			}
			with, err := Create(NewRequest{Template: template, Name: "tested", Location: t.TempDir(), ModulePath: "example.com/tested", SampleTest: true})
			if err != nil {
				t.Fatal(err)
			}
			if len(testFilesIn(t, with.Root)) == 0 {
				t.Fatal("with the option there must be a test file")
			}
			for _, root := range []string{without.Root, with.Root} {
				command := exec.Command("go", "test", "./...")
				command.Dir = root
				if output, err := command.CombinedOutput(); err != nil {
					t.Fatalf("go test in %s: %v\n%s", root, err, output)
				}
			}
		})
	}
}

func testFilesIn(t *testing.T, root string) []string {
	t.Helper()
	var names []string
	filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err == nil && !entry.IsDir() && strings.HasSuffix(path, "_test.go") {
			names = append(names, path)
		}
		return nil
	})
	return names
}

func TestScaffoldWritesReadmeGitignoreAndEnvExample(t *testing.T) {
	requireTool(t, "go")
	with, err := Create(NewRequest{Template: TemplateEmpty, Name: "scaffolded", Location: t.TempDir(), ModulePath: "example.com/s", Scaffold: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"README.md", ".gitignore", ".env.example"} {
		if _, err := os.Stat(filepath.Join(with.Root, name)); err != nil {
			t.Errorf("scaffold should write %s: %v", name, err)
		}
	}
	example, _ := os.ReadFile(filepath.Join(with.Root, ".env.example"))
	if strings.Contains(string(example), "=") {
		t.Errorf(".env.example must hold no values: %q", example)
	}
	without, err := Create(NewRequest{Template: TemplateEmpty, Name: "bare", Location: t.TempDir(), ModulePath: "example.com/b"})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"README.md", ".gitignore", ".env.example"} {
		if _, err := os.Stat(filepath.Join(without.Root, name)); err == nil {
			t.Errorf("without the scaffold option %s must not exist", name)
		}
	}
}

// Preview and Create share one plan, so the list the dialog shows is what ends up on disk.
func TestPreviewListsExactlyWhatCreateWrites(t *testing.T) {
	requireTool(t, "go")
	for _, template := range []string{TemplateCLI, TemplateLibrary, TemplateHTTP, TemplateEmpty, TemplateWorkspace} {
		for _, options := range []struct{ sample, scaffold bool }{{false, false}, {true, true}} {
			request := NewRequest{Template: template, Name: "demo", Location: t.TempDir(), ModulePath: "example.com/demo", SampleTest: options.sample, Scaffold: options.scaffold}
			planned, err := Preview(request)
			if err != nil {
				t.Fatalf("%s: %v", template, err)
			}
			created, err := Create(request)
			if err != nil {
				t.Fatalf("%s: %v", template, err)
			}
			var written []string
			filepath.WalkDir(created.Root, func(path string, entry os.DirEntry, err error) error {
				if err == nil && !entry.IsDir() {
					relative, _ := filepath.Rel(created.Root, path)
					written = append(written, filepath.ToSlash(relative))
				}
				return nil
			})
			sort.Strings(written)
			if strings.Join(planned, ",") != strings.Join(written, ",") {
				t.Errorf("%s %+v: preview %v, written %v", template, options, planned, written)
			}
		}
	}
}

func TestCreateCanAddTheModuleToAnExistingWorkspace(t *testing.T) {
	requireTool(t, "go")
	work := t.TempDir()
	command := exec.Command("go", "work", "init")
	command.Dir = work
	command.Env = append(os.Environ(), "GOTOOLCHAIN=local")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("go work init: %v\n%s", err, output)
	}
	if _, err := Create(NewRequest{Template: TemplateCLI, Name: "added", Location: work, ModulePath: "example.com/added", WorkDir: work}); err != nil {
		t.Fatal(err)
	}
	content, _ := os.ReadFile(filepath.Join(work, "go.work"))
	if !strings.Contains(string(content), "./added") {
		t.Fatalf("go.work should list the new module:\n%s", content)
	}
	if _, err := Create(NewRequest{Template: TemplateCLI, Name: "elsewhere", Location: t.TempDir(), ModulePath: "example.com/e", WorkDir: work}); err == nil {
		t.Fatal("a module outside the workspace folder must not be added to it")
	}
	if _, err := Create(NewRequest{Template: TemplateCLI, Name: "nowork", Location: t.TempDir(), ModulePath: "example.com/n", WorkDir: t.TempDir()}); err == nil {
		t.Fatal("a folder without go.work must be refused")
	}
}
