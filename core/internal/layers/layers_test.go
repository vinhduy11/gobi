// Package layers holds the test that keeps the core's dependency direction honest (docs/architect/layers.md).
package layers

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const module = "gobi/core/"

// Layer of every package. A package may import only packages in a lower layer, and the rules below narrow that further.
var layerOf = map[string]int{
	"internal/wire": 0, "internal/rpc": 0, "internal/textlines": 0, // foundation: no internal imports
	"internal/lsp": 1, "internal/langsvc": 1, "internal/project": 1, "internal/pty": 1, "internal/runner": 1, "internal/search": 1, "internal/pprof": 1, "internal/debugger": 1, "internal/gitsvc": 1, "internal/toolchain": 1, "internal/logfile": 1, // services
	"internal/ipc":    2, // transport
	"internal/daemon": 3, // composition: wires transport to services
	"cmd/gobid":       4, // entry point
}

// A service imports the foundation and nothing else; transport imports the foundation and nothing else.
// Composition and the entry point may import any lower layer.
func violation(from string, imports []string, layerOf map[string]int) string {
	fromLayer, known := layerOf[from]
	if !known {
		return fmt.Sprintf("%s is not assigned to a layer: add it to layerOf", from)
	}
	for _, imported := range imports {
		toLayer, known := layerOf[imported]
		if !known {
			return fmt.Sprintf("%s imports %s, which is not assigned to a layer", from, imported)
		}
		switch {
		case toLayer >= fromLayer:
			return fmt.Sprintf("%s (layer %d) imports %s (layer %d): imports must point to a lower layer", from, fromLayer, imported, toLayer)
		case (fromLayer == 1 || fromLayer == 2) && toLayer != 0:
			return fmt.Sprintf("%s (layer %d) may import only the foundation, but imports %s (layer %d)", from, fromLayer, imported, toLayer)
		}
	}
	return ""
}

func TestRuleAcceptsAndRefusesTheRightImports(t *testing.T) {
	tests := map[string]struct {
		from    string
		imports []string
		want    bool // true: a violation is expected
	}{
		"service uses the foundation":      {"internal/lsp", []string{"internal/rpc"}, false},
		"service uses another service":     {"internal/lsp", []string{"internal/langsvc"}, true},
		"service uses the transport":       {"internal/project", []string{"internal/ipc"}, true},
		"transport uses the foundation":    {"internal/ipc", []string{"internal/wire", "internal/rpc"}, false},
		"transport uses a service":         {"internal/ipc", []string{"internal/lsp"}, true},
		"foundation imports anything":      {"internal/wire", []string{"internal/rpc"}, true},
		"composition uses every lower one": {"internal/daemon", []string{"internal/ipc", "internal/lsp", "internal/wire"}, false},
		"nothing imports composition":      {"internal/lsp", []string{"internal/daemon"}, true},
		"entry point uses composition":     {"cmd/gobid", []string{"internal/daemon"}, false},
		"unknown package":                  {"internal/newthing", nil, true},
		"unknown import":                   {"internal/daemon", []string{"internal/newthing"}, true},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			if got := violation(test.from, test.imports, layerOf) != ""; got != test.want {
				t.Fatalf("violation(%s, %v) = %q, want violation=%v", test.from, test.imports, violation(test.from, test.imports, layerOf), test.want)
			}
		})
	}
}

// TestCoreFollowsTheLayers reads the imports of every package under core/.
func TestCoreFollowsTheLayers(t *testing.T) {
	root := filepath.Join("..", "..")
	imports := map[string]map[string]bool{}
	for _, area := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, area), func(path string, entry os.DirEntry, err error) error {
			if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return err
			}
			dir, _ := filepath.Rel(root, filepath.Dir(path))
			dir = filepath.ToSlash(dir)
			if dir == "internal/layers" || strings.HasSuffix(dir, "/fakelsp") || strings.HasSuffix(dir, "/fakedap") || strings.Contains(dir, "/testdata") {
				return nil
			}
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				return err
			}
			if imports[dir] == nil {
				imports[dir] = map[string]bool{}
			}
			for _, spec := range file.Imports {
				if name := strings.Trim(spec.Path.Value, `"`); strings.HasPrefix(name, module) {
					imports[dir][strings.TrimPrefix(name, module)] = true
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	packages := make([]string, 0, len(imports))
	for dir := range imports {
		packages = append(packages, dir)
	}
	sort.Strings(packages)
	for _, dir := range packages {
		var list []string
		for imported := range imports[dir] {
			list = append(list, imported)
		}
		sort.Strings(list)
		if problem := violation(dir, list, layerOf); problem != "" {
			t.Error(problem)
		}
	}
}
