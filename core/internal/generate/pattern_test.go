package generate

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// patternCase renders one pattern in an empty package "demo" and checks it against testdata/golden/pattern-<name>.golden.
// example is a _test.go file that exercises the generated code in a real module.
type patternCase struct {
	name, id  string
	goVersion string
	values    []ParamValue
	example   string
}

func allPatternCases() []patternCase {
	var all []patternCase
	all = append(all, creationalCases()...)
	all = append(all, structuralCases()...)
	all = append(all, behavioralCases()...)
	return all
}

// patternIDs is the catalogue, in the order of the Design Pattern submenu.
var patternIDs = []string{
	"factory-method", "abstract-factory", "builder", "prototype", "singleton",
	"adapter", "bridge", "composite", "decorator", "facade", "flyweight", "proxy",
	"chain-of-responsibility", "command", "iterator", "mediator", "memento", "observer", "state", "strategy",
	"template-method", "visitor",
}

const emptyPackage = "package demo\n"

func (c patternCase) request() Request {
	return Request{
		Version: 11, Item: c.id, GoVersion: c.goVersion, Values: c.values,
		Context: Context{Path: "/p/x.go", Package: "demo", Source: emptyPackage, Kind: KindFile},
	}
}

func patternOutputs(t *testing.T, c patternCase) map[string]string {
	t.Helper()
	return outputs(t, goldenCase{name: c.name, req: c.request()})
}

func TestEveryPatternHasACaseAndAGolden(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range allPatternCases() {
		seen[c.id] = true
	}
	for _, id := range patternIDs {
		if !seen[id] {
			t.Errorf("no case for %s", id)
		}
	}
	if len(patternIDs) != 22 {
		t.Errorf("the catalogue has %d patterns, want 22", len(patternIDs))
	}
}

func TestPatternsMatchTheirGoldens(t *testing.T) {
	for _, c := range allPatternCases() {
		t.Run(c.name, func(t *testing.T) { checkGolden(t, "pattern-"+c.name, patternOutputs(t, c)) })
	}
}

// The generated code and its example test must pass the real toolchain: gofmt -l empty, go vet, go test.
func TestPatternsBuildVetAndTest(t *testing.T) {
	for _, c := range allPatternCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			dir := t.TempDir()
			version := "1.22"
			if c.goVersion != "" {
				version = c.goVersion
			}
			files := patternOutputs(t, c)
			files["go.mod"] = "module example.com/demo\n\ngo " + version + "\n"
			files["example_test.go"] = "package demo\n\n" + c.example
			for name, content := range files {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			checkToolchain(t, dir)
		})
	}
}

func patternItemIDs(t *testing.T, ctx Context) []string {
	t.Helper()
	items, err := List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, item := range items {
		if item.Group != "" {
			ids = append(ids, item.ID)
		}
	}
	return ids
}

func TestPatternsAreOfferedInAFileAndAnEmptyFolderButNotInAFunction(t *testing.T) {
	cases := []struct {
		name string
		ctx  Context
		want []string
	}{
		{"file with code", Context{Package: "demo", Source: "package demo\n\nvar X = 1\n", Kind: KindFile}, patternIDs},
		{"empty file", Context{Package: "demo", Kind: KindEmpty}, patternIDs},
		{"empty folder", Context{Path: "/p", Kind: KindEmpty}, patternIDs},
		{"inside a function", Context{Package: "demo", Path: "/p/a.go", Source: "package demo\n\nfunc A() {}\n", Kind: KindFunc, Name: "A"}, nil},
	}
	for _, c := range cases {
		if got := patternItemIDs(t, c.ctx); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: patterns = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPatternItemsDescribeTheirGroupAndParameters(t *testing.T) {
	items, err := List(Context{Package: "demo", Kind: KindEmpty})
	if err != nil {
		t.Fatal(err)
	}
	groups := map[string]int{}
	for _, item := range items {
		if item.Group == "" {
			continue
		}
		groups[item.Group]++
		if len(item.Params) == 0 || item.Detail == "" {
			t.Errorf("%s: params %v detail %q", item.ID, item.Params, item.Detail)
		}
		for _, p := range item.Params {
			if p.Key == "" || p.Label == "" || len(p.Default) == 0 || p.Kind == "" {
				t.Errorf("%s: incomplete parameter %+v", item.ID, p)
			}
		}
	}
	if want := map[string]int{"creational": 5, "structural": 7, "behavioral": 10}; !reflect.DeepEqual(groups, want) {
		t.Errorf("groups = %v, want %v", groups, want)
	}
}

func mustRender(t *testing.T, req Request) Result {
	t.Helper()
	result, err := Render(req)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

// appliedText is the file after the edits of a render.
func appliedText(t *testing.T, req Request) string {
	t.Helper()
	got, err := ApplyEdits(req.Source, mustRender(t, req).Edits)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func patternRequest(id string, source string, values ...ParamValue) Request {
	return Request{Item: id, Values: values, Context: Context{Path: "/p/x.go", Package: "demo", Source: source, Kind: KindFile}}
}

func TestPatternRenderEchoesTheVersionAndPreviewHasNoEdits(t *testing.T) {
	req := patternRequest("singleton", emptyPackage)
	req.Version = 99
	preview, err := Preview(req)
	if err != nil {
		t.Fatal(err)
	}
	rendered := mustRender(t, req)
	if preview.Version != 99 || rendered.Version != 99 {
		t.Errorf("versions %d, %d", preview.Version, rendered.Version)
	}
	if len(preview.Edits) != 0 || len(preview.Files) != 0 || len(rendered.Edits) == 0 {
		t.Errorf("preview %+v rendered %+v", preview, rendered)
	}
	if preview.Text != rendered.Text || !reflect.DeepEqual(preview.Imports, []string{"sync"}) {
		t.Errorf("preview text/imports differ: %v %q", preview.Imports, preview.Text)
	}
}

func TestPatternHeaderNamesThePatternAndLinksReference(t *testing.T) {
	for _, id := range patternIDs {
		text := appliedText(t, patternRequest(id, emptyPackage))
		if !strings.Contains(text, "// ") || !strings.Contains(text, "https://refactoring.guru/design-patterns/") {
			t.Errorf("%s: no reference link in\n%s", id, text)
		}
	}
	for _, id := range []string{"singleton", "iterator", "strategy", "decorator"} {
		text := appliedText(t, patternRequest(id, emptyPackage))
		if !strings.Contains(text, "Simpler in Go") {
			t.Errorf("%s: missing the simpler-idiom note", id)
		}
	}
}

func TestPatternInsertsIntoTheCurrentFileAfterExistingCode(t *testing.T) {
	src := "package demo\n\nimport \"fmt\"\n\nfunc hello() { fmt.Println(\"hi\") }\n"
	result := mustRender(t, patternRequest("singleton", src))
	got, err := ApplyEdits(src, result.Edits)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "import (\n\t\"fmt\"\n\t\"sync\"\n)") || !strings.Contains(got, "func hello()") || !strings.Contains(got, "func Instance() *Config") {
		t.Errorf("got\n%s", got)
	}
	if strings.Index(got, "func hello") > strings.Index(got, "func Instance") {
		t.Errorf("the pattern must come after the existing code:\n%s", got)
	}
}

func TestPatternReusesAnAliasedImport(t *testing.T) {
	src := "package demo\n\nimport sy \"sync\"\n\nvar _ sy.Mutex\n"
	got, err := ApplyEdits(src, mustRender(t, patternRequest("singleton", src)).Edits)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "sy.Once") || strings.Count(got, "\"sync\"") != 1 {
		t.Errorf("got\n%s", got)
	}
}

func TestPatternCanCreateItsOwnFileInThePackage(t *testing.T) {
	dir := t.TempDir()
	src := "package demo\n\nvar X = 1\n"
	req := patternRequest("chain-of-responsibility", src)
	req.Path = filepath.Join(dir, "x.go")
	req.Target = TargetFile
	result := mustRender(t, req)
	want := filepath.Join(dir, "chain_of_responsibility.go")
	if len(result.Edits) != 0 || len(result.Files) != 1 || result.Files[0].Path != want {
		t.Fatalf("edits %v files %v", result.Edits, result.Files)
	}
	content := result.Files[0].Content
	if !strings.HasPrefix(content, "package demo\n") || !strings.Contains(content, "import \"context\"") {
		t.Errorf("content\n%s", content)
	}
	if err := os.WriteFile(want, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Render(req); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Errorf("a second render must not overwrite: %v", err)
	}
}

func TestPatternInAnEmptyFolderCreatesAFileInThatFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "orders")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	result := mustRender(t, Request{Item: "singleton", Target: TargetFile, Context: Context{Path: dir, Kind: KindEmpty}})
	if len(result.Files) != 1 || result.Files[0].Path != filepath.Join(dir, "singleton.go") ||
		!strings.HasPrefix(result.Files[0].Content, "package orders\n") {
		t.Errorf("files %+v", result.Files)
	}
	if _, err := Render(Request{Item: "singleton", Context: Context{Path: dir, Kind: KindEmpty}}); err == nil {
		t.Error("there is no current file to insert into")
	}
}

func TestPatternParametersAreValidated(t *testing.T) {
	v := func(key string, values ...string) ParamValue { return ParamValue{Key: key, Values: values} }
	cases := []struct {
		name string
		req  Request
		want string
	}{
		{"not an identifier", patternRequest("strategy", emptyPackage, v("strategy", "my strategy")), "not a valid Go name"},
		{"starts with a digit", patternRequest("singleton", emptyPackage, v("type", "1x")), "not a valid Go name"},
		{"duplicate in a list", patternRequest("strategy", emptyPackage, v("strategies", "Fast", "fast")), "twice"},
		{"list repeats the interface", patternRequest("strategy", emptyPackage, v("strategies", "Strategy", "Fast")), "twice"},
		{"unknown parameter", patternRequest("singleton", emptyPackage, v("colour", "red")), "unknown parameter"},
		{"two values for one", patternRequest("singleton", emptyPackage, v("type", "A", "B")), "one value"},
		{"not a signature", patternRequest("strategy", emptyPackage, v("method", "func Do()")), "not a method signature"},
		{"two methods", patternRequest("strategy", emptyPackage, v("method", "A()\nB()")), "not a method signature"},
		{"unnamed parameter", patternRequest("strategy", emptyPackage, v("method", "Do(string) error")), "name every parameter"},
		{"unknown package", patternRequest("strategy", emptyPackage, v("method", "Do(x zzz.T)")), "unknown package"},
		{"bad field", patternRequest("builder", emptyPackage, v("fields", "addr")), "name and a type"},
		{"bad field type", patternRequest("builder", emptyPackage, v("fields", "addr []")), "not a type"},
		{"duplicate field", patternRequest("builder", emptyPackage, v("fields", "addr string", "addr int")), "twice"},
		{"step named Run", patternRequest("template-method", emptyPackage, v("steps", "Run")), "reserved"},
		{"does not apply", Request{Item: "nope", Context: Context{Package: "demo", Source: emptyPackage, Kind: KindFile}}, "does not apply"},
	}
	for _, c := range cases {
		_, err := Render(c.req)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want it to contain %q", c.name, err, c.want)
		}
	}
}

func TestPatternRefusesNamesThatCollideWithExistingDeclarations(t *testing.T) {
	cases := []struct{ id, source string }{
		{"singleton", "package demo\n\ntype Config struct{}\n"},
		{"singleton", "package demo\n\nfunc Instance() int { return 1 }\n"},
		{"strategy", "package demo\n\nvar Fast = 1\n"},
		{"builder", "package demo\n\nfunc NewServer() {}\n"},
		{"observer", "package demo\n\nfunc (t *Topic) Notify() {}\n"},
	}
	for _, c := range cases {
		_, err := Render(patternRequest(c.id, c.source))
		if err == nil || !strings.Contains(err.Error(), "already declared") {
			t.Errorf("%s over %q: err = %v", c.id, c.source, err)
		}
	}
}

func TestPatternSkipsAnAdapteeThatAlreadyExists(t *testing.T) {
	src := "package demo\n\ntype LegacyPrinter struct{}\n"
	text := appliedText(t, patternRequest("adapter", src))
	if strings.Count(text, "type LegacyPrinter struct") != 1 || !strings.Contains(text, "*LegacyPrinter") {
		t.Errorf("text\n%s", text)
	}
}

func TestPatternSignatureControlsTheGeneratedMethod(t *testing.T) {
	text := appliedText(t, patternRequest("strategy", emptyPackage,
		ParamValue{Key: "strategy", Values: []string{"pricing"}},
		ParamValue{Key: "method", Values: []string{"Price(ctx context.Context, items ...string) (float64, error)"}},
		ParamValue{Key: "strategies", Values: []string{"flat", "tiered"}},
	))
	for _, want := range []string{
		"type Pricing interface {\n\tPrice(ctx context.Context, items ...string) (float64, error)\n}",
		"type Flat struct{}", "type Tiered struct{}", "return r.strategy.Price(ctx, items...)", "import \"context\"",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
}

func TestPatternReceiverAvoidsParameterNames(t *testing.T) {
	text := appliedText(t, patternRequest("strategy", emptyPackage,
		ParamValue{Key: "method", Values: []string{"Run(r int) int"}},
	))
	if strings.Contains(text, "(r *Runner) Run(r int)") {
		t.Errorf("receiver shadows a parameter:\n%s", text)
	}
}

func TestPatternGoVersionPicksTheIteratorForm(t *testing.T) {
	for version, modern := range map[string]bool{"": false, "1.22": false, "go1.22.3": false, "1.23": true, "go1.24.1": true, "1.23.0": true, "2": false} {
		req := patternRequest("iterator", emptyPackage)
		req.GoVersion = version
		text := appliedText(t, req)
		if got := strings.Contains(text, "iter.Seq"); got != modern {
			t.Errorf("go %q: iter.Seq = %v, want %v\n%s", version, got, modern, text)
		}
		if got := strings.Contains(text, "Next() bool"); got == modern {
			t.Errorf("go %q: Next form = %v, want %v", version, got, !modern)
		}
	}
}

func TestEveryPatternRenders(t *testing.T) {
	for _, id := range patternIDs {
		if text := appliedText(t, patternRequest(id, emptyPackage)); !strings.HasPrefix(text, "package demo") {
			t.Errorf("%s: %q", id, text)
		}
	}
}
