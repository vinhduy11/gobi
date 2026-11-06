package generate

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the golden files")

const serverSource = `package demo

import "log/slog"

type Server struct {
	addr   string
	port   int
	logger *slog.Logger
}
`

var serverFields = []Field{
	{Name: "addr", Type: "string"},
	{Name: "port", Type: "int"},
	{Name: "logger", Type: "*slog.Logger"},
}

type goldenCase struct {
	name string
	req  Request
}

func goldenCases() []goldenCase {
	structCtx := Context{Path: "/p/server.go", Package: "demo", Source: serverSource, Kind: KindStruct, Name: "Server", Fields: serverFields}
	return []goldenCase{
		{"constructor", Request{Item: ItemConstructor, Context: structCtx}},
		{"accessors", Request{Item: ItemAccessors, Context: structCtx, Selected: []string{"addr", "port"}}},
		{"string", Request{Item: ItemString, Context: structCtx}},
		{"options", Request{Item: ItemOptions, Context: structCtx}},
		{"error-type", Request{Item: ItemErrorType, AskedName: "parse", Context: structCtx}},
		{"test", Request{Item: ItemTest, Context: Context{
			Path: "/p/calc.go", Package: "demo", Kind: KindFunc, Name: "Divide",
			Source: "package demo\n\nimport \"errors\"\n\nfunc Divide(a, b int) (int, error) {\n\tif b == 0 {\n\t\treturn 0, errors.New(\"divide by zero\")\n\t}\n\treturn a / b, nil\n}\n",
			Params: []Field{{Name: "a", Type: "int"}, {Name: "b", Type: "int"}}, Results: []string{"int", "error"},
		}}},
		{"main", Request{Item: ItemMain, Context: Context{Path: "/p/main.go", Package: "main", Kind: KindEmpty}}},
		{"http-handler", Request{Item: ItemHandler, AskedName: "orders", Context: Context{
			Path: "/p/h.go", Package: "demo", Kind: KindEmpty, Source: "package demo\n",
		}}},
		{"mock", Request{Item: ItemMock, Context: Context{
			Path: "/p/store.go", Package: "demo", Kind: KindInterface, Name: "Store",
			Source: "package demo\n\ntype Store interface {\n\tGet(id string) (string, error)\n\tPut(id, value string) error\n\tClose()\n\tKeys(prefix ...string) []string\n}\n",
			Methods: []Method{
				{Name: "Get", Params: []Field{{Name: "id", Type: "string"}}, Results: []string{"string", "error"}},
				{Name: "Put", Params: []Field{{Name: "id", Type: "string"}, {Name: "value", Type: "string"}}, Results: []string{"error"}},
				{Name: "Close"},
				{Name: "Keys", Params: []Field{{Name: "prefix", Type: "...string"}}, Results: []string{"[]string"}},
			},
		}}},
	}
}

// outputs renders a case and returns the resulting files by path (the edited file and any new file).
func outputs(t *testing.T, c goldenCase) map[string]string {
	t.Helper()
	req := c.req
	req.Version = 7
	result, err := Render(req)
	if err != nil {
		t.Fatalf("%s: %v", c.name, err)
	}
	if result.Version != 7 {
		t.Errorf("%s: version = %d, want 7", c.name, result.Version)
	}
	files := map[string]string{filepath.Base(req.Path): req.Source}
	if len(result.Edits) > 0 {
		out, err := ApplyEdits(req.Source, result.Edits)
		if err != nil {
			t.Fatal(err)
		}
		files[filepath.Base(req.Path)] = out
	}
	for _, f := range result.Files {
		files[filepath.Base(f.Path)] = f.Content
	}
	return files
}

func TestEveryItemMatchesItsGolden(t *testing.T) {
	for _, c := range goldenCases() {
		t.Run(c.name, func(t *testing.T) {
			checkGolden(t, c.name, outputs(t, c))
		})
	}
}

// checkGolden compares the files with testdata/golden/<name>.golden: the files concatenated in name order, each under a
// "// file:" line.
func checkGolden(t *testing.T, name string, files map[string]string) {
	t.Helper()
	var names []string
	for file := range files {
		names = append(names, file)
	}
	var got strings.Builder
	for _, file := range sortedStrings(names) {
		got.WriteString("// file: " + file + "\n" + files[file])
	}
	path := filepath.Join("testdata", "golden", name+".golden")
	if *update {
		if err := os.WriteFile(path, []byte(got.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.String() != string(want) {
		t.Errorf("output differs from %s\n--- got\n%s\n--- want\n%s", path, got.String(), want)
	}
}

func sortedStrings(in []string) []string {
	out := append([]string{}, in...)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

// The generated code must be accepted by the real toolchain: gofmt -l prints nothing, go vet and go test pass.
func TestGeneratedCodeBuildsVetsAndTests(t *testing.T) {
	for _, c := range goldenCases() {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			write := func(name, content string) {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			write("go.mod", "module example.com/demo\n\ngo 1.22\n")
			for name, content := range outputs(t, c) {
				write(name, content)
			}
			if c.name == "main" {
				write("main_test.go", "package main\n\nimport \"testing\"\n\nfunc TestRun(t *testing.T) {\n\tif err := run(); err != nil {\n\t\tt.Fatal(err)\n\t}\n}\n")
			}
			if c.name == "http-handler" {
				write("h_test.go", "package demo\n\nimport (\n\t\"net/http\"\n\t\"net/http/httptest\"\n\t\"testing\"\n)\n\nfunc TestOrdersHandler(t *testing.T) {\n\trec := httptest.NewRecorder()\n\tordersHandler(rec, httptest.NewRequest(http.MethodGet, \"/\", nil))\n\tif rec.Code != http.StatusOK || rec.Body.String() != \"ok\\n\" {\n\t\tt.Fatalf(\"got %d %q\", rec.Code, rec.Body.String())\n\t}\n\trec = httptest.NewRecorder()\n\tordersHandler(rec, httptest.NewRequest(http.MethodPost, \"/\", nil))\n\tif rec.Code != http.StatusMethodNotAllowed {\n\t\tt.Fatalf(\"POST got %d\", rec.Code)\n\t}\n}\n")
			}
			if c.name == "error-type" {
				write("e_test.go", "package demo\n\nimport (\n\t\"errors\"\n\t\"testing\"\n)\n\nfunc TestParseError(t *testing.T) {\n\tcause := errors.New(\"boom\")\n\terr := error(&ParseError{Op: \"x\", Err: cause})\n\tif !errors.Is(err, ErrParse) || !errors.Is(err, cause) {\n\t\tt.Fatal(\"errors.Is must see both\")\n\t}\n\tvar pe *ParseError\n\tif !errors.As(err, &pe) || err.Error() != \"parse: x: boom\" {\n\t\tt.Fatal(err)\n\t}\n}\n")
			}
			checkToolchain(t, dir)
		})
	}
}

// checkToolchain runs the real toolchain on a temp module: gofmt -l prints nothing, go vet and go test pass. Nothing is
// fetched (GOPROXY=off).
func checkToolchain(t *testing.T, dir string) {
	t.Helper()
	run := func(name string, args ...string) string {
		cmd := exec.Command(name, args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GOPROXY=off", "GOFLAGS=-mod=mod", "GOTOOLCHAIN=local")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s %v: %v\n%s", name, args, err, out)
		}
		return string(out)
	}
	if out := run("gofmt", "-l", "."); out != "" {
		t.Errorf("gofmt -l lists %q", out)
	}
	run("go", "vet", "./...")
	run("go", "test", "./...")
}

func TestStringPicksTheVerbByFieldType(t *testing.T) {
	src := "package demo\n\nimport (\n\t\"fmt\"\n\t\"time\"\n)\n\ntype Level string\ntype Count int\n\ntype T struct {\n\ta string\n}\n\nvar _ = fmt.Sprint\nvar _ time.Duration\n"
	fields := []Field{
		{Name: "name", Type: "string"},
		{Name: "level", Type: "Level", Underlying: "string"},
		{Name: "n", Type: "int"},
		{Name: "big", Type: "uint64"},
		{Name: "ok", Type: "bool"},
		{Name: "next", Type: "*T"},
		{Name: "tags", Type: "[]string"},
		{Name: "wait", Type: "time.Duration", Underlying: "int64"}, // a Stringer: must not print as a raw number
		{Name: "count", Type: "Count", Underlying: "int"},
		{Name: "mu", Type: "sync.Mutex"},
		{Name: "ratio", Type: "float64"},
	}
	result, err := Preview(Request{Item: ItemString, Context: Context{Package: "demo", Source: src, Kind: KindStruct, Name: "T", Fields: fields}})
	if err != nil {
		t.Fatal(err)
	}
	want := `"T{name: %s, level: %s, n: %d, big: %d, ok: %t, next: %v, tags: %v, wait: %v, count: %v, ratio: %v}", t.name, t.level, t.n, t.big, t.ok, t.next, t.tags, t.wait, t.count, t.ratio)`
	if !strings.Contains(result.Text, want) {
		t.Errorf("got\n%s\nwant it to contain\n%s", result.Text, want)
	}
	if strings.Contains(result.Text, "(t *T)") && strings.Contains(result.Text, ", t)") {
		t.Error("the receiver itself must never be formatted")
	}
}

func TestAccessorsAreNamedWithoutGetAndFollowInitialisms(t *testing.T) {
	src := "package demo\n\ntype U struct {\n\tuserID string\n\turl string\n}\n"
	result, err := Preview(Request{Item: ItemAccessors, Context: Context{Package: "demo", Source: src, Kind: KindStruct, Name: "U",
		Fields: []Field{{Name: "userID", Type: "string"}, {Name: "url", Type: "string"}, {Name: "Public", Type: "int"}}}})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"UserID() string", "SetUserID(userID string)", "URL() string", "SetURL(url string)"} {
		if !strings.Contains(result.Text, want) {
			t.Errorf("missing %q in\n%s", want, result.Text)
		}
	}
	if strings.Contains(result.Text, "Get") || strings.Contains(result.Text, "Public") {
		t.Errorf("no Get prefix and no exported fields:\n%s", result.Text)
	}
}

func TestListFollowsTheCaret(t *testing.T) {
	ids := func(ctx Context) []string {
		items, err := List(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, i := range items {
			out = append(out, i.ID)
		}
		return out
	}
	structCtx := Context{Package: "demo", Source: serverSource, Kind: KindStruct, Name: "Server", Fields: serverFields}
	cases := []struct {
		name string
		ctx  Context
		want []string
	}{
		{"struct", structCtx, []string{"constructor", "options", "accessors", "string", "error-type"}},
		{"struct with constructor and String", func() Context {
			c := structCtx
			c.Source += "\nfunc NewServer() *Server { return nil }\nfunc (s *Server) String() string { return \"\" }\nfunc (s *Server) Addr() string { return s.addr }\nfunc (s *Server) SetAddr(a string) { s.addr = a }\nfunc (s *Server) Port() int { return s.port }\nfunc (s *Server) SetPort(p int) { s.port = p }\nfunc (s *Server) Logger() *slog.Logger { return s.logger }\nfunc (s *Server) SetLogger(l *slog.Logger) { s.logger = l }\n"
			return c
		}(), []string{"error-type"}},
		{"struct without fields", Context{Package: "demo", Source: "package demo\n\ntype E struct{}\n", Kind: KindStruct, Name: "E"}, nil},
		{"interface", Context{Package: "demo", Source: "package demo\n\ntype S interface{ A() }\n", Kind: KindInterface, Name: "S"}, []string{"mock"}},
		{"func", Context{Package: "demo", Path: "/p/a.go", Source: "package demo\n\nfunc A() {}\n", Kind: KindFunc, Name: "A"}, []string{"test"}},
		{"func in a test file", Context{Package: "demo", Path: "/p/a_test.go", Source: "package demo\n\nfunc A() {}\n", Kind: KindFunc, Name: "A"}, nil},
		{"empty main package", Context{Package: "main", Kind: KindEmpty}, append([]string{"main", "http-handler", "error-type"}, patternIDs...)},
		{"empty library package", Context{Package: "demo", Kind: KindEmpty}, append([]string{"http-handler", "error-type"}, patternIDs...)},
		{"file with code", Context{Package: "demo", Source: "package demo\n\nvar X = 1\n", Kind: KindFile}, append([]string{"http-handler", "error-type"}, patternIDs...)},
		{"main package that has main", Context{Package: "main", Source: "package main\n\nfunc main() {}\n", Kind: KindFile}, append([]string{"http-handler", "error-type"}, patternIDs...)},
	}
	for _, c := range cases {
		if got := ids(c.ctx); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: items = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestRenderRefusesAnItemThatDoesNotApply(t *testing.T) {
	_, err := Render(Request{Item: ItemMock, Context: Context{Package: "demo", Source: serverSource, Kind: KindStruct, Name: "Server", Fields: serverFields}})
	if err == nil || !strings.Contains(err.Error(), "does not apply") {
		t.Errorf("err = %v", err)
	}
}

func TestTestItemRefusesAnExistingTestFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a_test.go"), []byte("package demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Render(Request{Item: ItemTest, Context: Context{Package: "demo", Path: filepath.Join(dir, "a.go"), Source: "package demo\n\nfunc A() {}\n", Kind: KindFunc, Name: "A"}})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Errorf("err = %v", err)
	}
}

func TestTestItemCopiesImportsOfParameterTypes(t *testing.T) {
	src := "package demo\n\nimport (\n\t\"context\"\n\tnethttp \"net/http\"\n)\n\nfunc Do(ctx context.Context, r *nethttp.Request, rest ...string) error { return nil }\n"
	result, err := Render(Request{Item: ItemTest, Context: Context{Package: "demo", Path: filepath.Join(t.TempDir(), "do.go"), Source: src, Kind: KindFunc, Name: "Do",
		Params: []Field{{Name: "ctx", Type: "context.Context"}, {Name: "r", Type: "*nethttp.Request"}, {Name: "rest", Type: "...string"}}, Results: []string{"error"}}})
	if err != nil {
		t.Fatal(err)
	}
	content := result.Files[0].Content
	for _, want := range []string{"nethttp \"net/http\"", "\"context\"", "context.Background()", "[]string", "tt.rest...", "*nethttp.Request"} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in\n%s", want, content)
		}
	}
}
