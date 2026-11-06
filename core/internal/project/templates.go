package project

import (
	"fmt"
	"strings"
	"unicode"
)

// Template names a client can ask for.
const (
	TemplateCLI       = "cli"
	TemplateLibrary   = "library"
	TemplateHTTP      = "http"
	TemplateConsumer  = "consumer"
	TemplateJob       = "job"
	TemplateEmpty     = "empty"
	TemplateWorkspace = "workspace"
)

// A template is its files plus the files added by the "sample test" option.
type template struct {
	files map[string]string
	tests map[string]string
}

var templates = map[string]template{
	TemplateCLI: {
		files: map[string]string{
			"main.go": `package main

import "fmt"

// greeting is the text the program prints; it is separate from main so a test can check it.
func greeting() string { return "Hello from {{name}}" }

func main() {
	fmt.Println(greeting())
}
`,
		},
		tests: map[string]string{
			"main_test.go": `package main

import "testing"

func TestGreeting(t *testing.T) {
	if greeting() == "" {
		t.Fatal("greeting must not be empty")
	}
}
`,
		},
	},
	TemplateLibrary: {
		files: map[string]string{
			"{{pkg}}.go": `// Package {{pkg}} is the {{name}} library.
package {{pkg}}

// Greeting returns the greeting for name.
func Greeting(name string) string {
	return "Hello, " + name
}
`,
		},
		tests: map[string]string{
			"{{pkg}}_test.go": `package {{pkg}}

import "testing"

func TestGreeting(t *testing.T) {
	if got, want := Greeting("Gobi"), "Hello, Gobi"; got != want {
		t.Fatalf("Greeting = %q, want %q", got, want)
	}
}
`,
		},
	},
	TemplateHTTP: {
		files: map[string]string{
			"main.go": `package main

import (
	"log"
	"net/http"
	"time"
)

// newMux holds the routes, so a test can call them without a network.
func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	return mux
}

func main() {
	server := &http.Server{Addr: ":8080", Handler: newMux(), ReadHeaderTimeout: 5 * time.Second}
	log.Println("{{name}} listening on", server.Addr)
	log.Fatal(server.ListenAndServe())
}
`,
		},
		tests: map[string]string{
			"main_test.go": `package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	recorder := httptest.NewRecorder()
	newMux().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("/healthz answered %d", recorder.Code)
	}
}
`,
		},
	},
	TemplateConsumer: consumerTemplate,
	TemplateJob:      jobTemplate,
	TemplateEmpty:    {},
}

// Render returns the files of a template (path to content) for the given module path and project name; the sample test
// files are included only when sampleTest is true.
func Render(name, modulePath, projectName string, sampleTest bool) (map[string]string, error) {
	source, ok := templates[name]
	if !ok {
		return nil, fmt.Errorf("unknown template %q", name)
	}
	replacer := strings.NewReplacer("{{module}}", modulePath, "{{name}}", projectName, "{{pkg}}", packageName(projectName))
	files := make(map[string]string, len(source.files)+len(source.tests))
	for path, content := range source.files {
		files[replacer.Replace(path)] = replacer.Replace(content)
	}
	if sampleTest {
		for path, content := range source.tests {
			files[replacer.Replace(path)] = replacer.Replace(content)
		}
	}
	return files, nil
}

// packageName turns a project name into a valid Go package name: lower-case letters and digits only,
// starting with a letter.
func packageName(name string) string {
	var builder strings.Builder
	for _, r := range strings.ToLower(name) {
		if unicode.IsLetter(r) && r < unicode.MaxASCII || unicode.IsDigit(r) && r < unicode.MaxASCII {
			builder.WriteRune(r)
		}
	}
	pkg := builder.String()
	if pkg == "" || !unicode.IsLetter(rune(pkg[0])) {
		pkg = "p" + pkg
	}
	return pkg
}
