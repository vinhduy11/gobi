package project

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the golden files")

// Every template with files must produce a module that is gofmt-clean, vets and passes its own tests, with no download.
func TestTemplatesAreFormattedVetAndPass(t *testing.T) {
	requireTool(t, "go")
	requireTool(t, "gofmt")
	for _, kind := range []string{TemplateCLI, TemplateLibrary, TemplateHTTP, TemplateConsumer, TemplateJob} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			files, err := Render(kind, "example.com/acme/widget", "widget", true)
			if err != nil {
				t.Fatal(err)
			}
			files["go.mod"] = "module example.com/acme/widget\n\ngo 1.22\n"
			for path, content := range files {
				if err := os.WriteFile(filepath.Join(dir, path), []byte(content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			run := func(name string, args ...string) string {
				command := exec.Command(name, args...)
				command.Dir = dir
				command.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GOPROXY=off")
				output, err := command.CombinedOutput()
				if err != nil {
					t.Fatalf("%s %v: %v\n%s", name, args, err, output)
				}
				return string(output)
			}
			if listed := run("gofmt", "-l", "."); strings.TrimSpace(listed) != "" {
				t.Errorf("gofmt -l lists %q", listed)
			}
			run("go", "vet", "./...")
			run("go", "test", "./...")
		})
	}
}

// Run with -update to rewrite testdata/templates after an intended change to a template.
func TestNewTemplatesMatchTheirGoldenFiles(t *testing.T) {
	for _, kind := range []string{TemplateConsumer, TemplateJob} {
		files, err := Render(kind, "example.com/acme/widget", "widget", true)
		if err != nil {
			t.Fatal(err)
		}
		var paths []string
		for path := range files {
			paths = append(paths, path)
		}
		sort.Strings(paths)
		for _, path := range paths {
			golden := filepath.Join("testdata", "templates", kind, path+".golden")
			if *update {
				if err := os.MkdirAll(filepath.Dir(golden), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(golden, []byte(files[path]), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(golden)
			if err != nil {
				t.Fatalf("%s/%s: %v (run go test -update)", kind, path, err)
			}
			if files[path] != string(want) {
				t.Errorf("%s/%s differs from %s", kind, path, golden)
			}
		}
	}
}
