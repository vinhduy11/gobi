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
	TemplateEmpty     = "empty"
	TemplateWorkspace = "workspace"
)

var templates = map[string]map[string]string{
	TemplateCLI: {
		"main.go": `package main

import "fmt"

func main() {
	fmt.Println("Hello from {{name}}")
}
`,
	},
	TemplateLibrary: {
		"{{pkg}}.go": `// Package {{pkg}} is the {{name}} library.
package {{pkg}}

// Greeting returns the greeting for name.
func Greeting(name string) string {
	return "Hello, " + name
}
`,
		"{{pkg}}_test.go": `package {{pkg}}

import "testing"

func TestGreeting(t *testing.T) {
	if got, want := Greeting("Gobi"), "Hello, Gobi"; got != want {
		t.Fatalf("Greeting = %q, want %q", got, want)
	}
}
`,
	},
	TemplateHTTP: {
		"main.go": `package main

import (
	"log"
	"net/http"
	"time"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	server := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Println("{{name}} listening on", server.Addr)
	log.Fatal(server.ListenAndServe())
}
`,
	},
	TemplateEmpty: {},
}

// Render returns the files of a template (path to content) for the given module path and project name.
func Render(template, modulePath, name string) (map[string]string, error) {
	source, ok := templates[template]
	if !ok {
		return nil, fmt.Errorf("unknown template %q", template)
	}
	replacer := strings.NewReplacer("{{module}}", modulePath, "{{name}}", name, "{{pkg}}", packageName(name))
	files := make(map[string]string, len(source))
	for path, content := range source {
		files[replacer.Replace(path)] = replacer.Replace(content)
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
