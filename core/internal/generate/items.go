package generate

import (
	"bytes"
	"errors"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"text/template"
)

// renderer collects the imports a template asks for through pkg.
type renderer struct {
	names map[string]string // import path -> name used in the file
	needs []importSpec
}

// pkg returns the name to write for an imported package, remembering that the import must be added when the file lacks it.
func (r *renderer) pkg(importPath string) string {
	if name, ok := r.names[importPath]; ok {
		return name
	}
	r.names[importPath] = defaultName(importPath)
	r.needs = append(r.needs, importSpec{Path: importPath})
	return r.names[importPath]
}

// use records an import with the alias the original file used, for types copied into a new file.
func (r *renderer) use(spec importSpec) {
	if _, ok := r.names[spec.Path]; ok {
		return
	}
	name := spec.Name
	if name == "" {
		name = defaultName(spec.Path)
	}
	r.names[spec.Path] = name
	r.needs = append(r.needs, spec)
}

// The templates. Data is prepared in Go so the templates stay free of logic.
var templates = template.Must(template.New("").Parse(`
{{define "constructor"}}// New{{.Type}} returns a {{.Type}} with its fields set.
func New{{.Type}}({{.Params}}) *{{.Type}} {
	return &{{.Type}}{
{{- range .Fields}}
		{{.Name}}: {{.Param}},
{{- end}}
	}
}{{end}}

{{define "accessors"}}{{range $i, $a := .Accessors}}{{if $i}}

{{end}}{{if $a.Getter}}// {{$a.Export}} returns the {{$a.Field}} field.
func ({{$.Recv}} *{{$.Type}}) {{$a.Export}}() {{$a.FieldType}} { return {{$.Recv}}.{{$a.Field}} }{{end}}{{if and $a.Getter $a.Setter}}

{{end}}{{if $a.Setter}}// Set{{$a.Export}} sets the {{$a.Field}} field.
func ({{$.Recv}} *{{$.Type}}) Set{{$a.Export}}({{$a.Param}} {{$a.FieldType}}) { {{$.Recv}}.{{$a.Field}} = {{$a.Param}} }{{end}}{{end}}{{end}}

{{define "string"}}// String implements fmt.Stringer.
func ({{.Recv}} *{{.Type}}) String() string {
	return {{.Fmt}}.Sprintf("{{.Type}}{ {{- .Layout -}} }"{{range .Fields}}, {{$.Recv}}.{{.Name}}{{end}})
}{{end}}

{{define "error-type"}}// Err{{.Base}} is the sentinel for {{.Words}} failures; test for it with errors.Is.
var Err{{.Base}} = {{.Errors}}.New("{{.Words}} failed")

// {{.Base}}Error describes a failed {{.Words}} and wraps the cause.
type {{.Base}}Error struct {
	Op  string // what was being done
	Err error  // the cause, may be nil
}

// Error implements the error interface.
func (e *{{.Base}}Error) Error() string {
	if e.Err == nil {
		return "{{.Words}}: " + e.Op
	}
	return "{{.Words}}: " + e.Op + ": " + e.Err.Error()
}

// Unwrap returns the cause so that errors.Is and errors.As see through the error.
func (e *{{.Base}}Error) Unwrap() error { return e.Err }

// Is reports whether target is Err{{.Base}}, so errors.Is(err, Err{{.Base}}) matches any {{.Base}}Error.
func (e *{{.Base}}Error) Is(target error) bool { return target == Err{{.Base}} }{{end}}

{{define "options"}}// {{.Type}}Option configures a {{.Type}} (the functional options pattern).
type {{.Type}}Option func(*{{.Type}})
{{range .Fields}}
// With{{.Export}} sets the {{.Name}} field.
func With{{.Export}}({{.Param}} {{.Type}}) {{$.Type}}Option {
	return func({{$.Recv}} *{{$.Type}}) { {{$.Recv}}.{{.Name}} = {{.Param}} }
}
{{end}}
// New{{.Type}} returns a {{.Type}} configured by opts.
func New{{.Type}}(opts ...{{.Type}}Option) *{{.Type}} {
	{{.Recv}} := &{{.Type}}{}
	for _, opt := range opts {
		opt({{.Recv}})
	}
	return {{.Recv}}
}{{end}}

{{define "test"}}func {{.TestName}}(t *testing.T) {
	tests := []struct {
		name string
{{- range .Fields}}
		{{.Name}} {{.Type}}
{{- end}}
	}{
		// Add cases here.
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
{{- if .Recv}}
			r := new({{.Recv}})
{{- end}}
			{{.Call}}
{{- if .HasErr}}
			if (err != nil) != tt.wantErr {
				t.Fatalf("{{.Label}}() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil {
				return
			}
{{- end}}
{{- range .Values}}
			if !{{$.Reflect}}.DeepEqual({{.Got}}, tt.{{.Want}}) {
				t.Errorf("{{$.Label}}() = %v, want %v", {{.Got}}, tt.{{.Want}})
			}
{{- end}}
		})
	}
}{{end}}

{{define "main"}}func main() {
	if err := run(); err != nil {
		{{.Fmt}}.Fprintln({{.OS}}.Stderr, err)
		{{.OS}}.Exit(1)
	}
}

func run() error {
	return nil
}{{end}}

{{define "http-handler"}}// {{.Name}} serves {{.Route}} requests.
func {{.Name}}(w {{.HTTP}}.ResponseWriter, r *{{.HTTP}}.Request) {
	if r.Method != {{.HTTP}}.MethodGet {
		{{.HTTP}}.Error(w, "method not allowed", {{.HTTP}}.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = {{.IO}}.WriteString(w, "ok\n")
}{{end}}

{{define "mock"}}// {{.Mock}} is a test double for {{.Type}}; set the Func field of each method a test calls.
type {{.Mock}} struct {
{{- range .Methods}}
	{{.Name}}Func func({{.ParamTypes}}){{.ResultType}}
{{- end}}
}

var _ {{.Type}} = (*{{.Mock}})(nil)
{{range .Methods}}
// {{.Name}} calls {{.Name}}Func and panics when it is not set.
func ({{$.Recv}} *{{$.Mock}}) {{.Name}}({{.Params}}){{.ResultType}} {
	if {{$.Recv}}.{{.Name}}Func == nil {
		panic("{{$.Mock}}.{{.Name}}: {{.Name}}Func is not set")
	}
	{{.Return}}{{$.Recv}}.{{.Name}}Func({{.Args}})
}
{{end}}{{end}}
`))

type fieldView struct {
	Name, Param, Type, Export string
}

func fieldViews(fields []Field) []fieldView {
	out := make([]fieldView, len(fields))
	for i, f := range fields {
		out[i] = fieldView{Name: f.Name, Param: local(f.Name), Type: f.Type, Export: exported(f.Name)}
	}
	return out
}

// pick returns the fields the user ticked, in declaration order; all named fields when nothing was ticked.
func pick(all []Field, selected []string) ([]Field, error) {
	all = namedFields(all)
	if len(selected) == 0 {
		return all, nil
	}
	want := map[string]bool{}
	for _, s := range selected {
		want[s] = true
	}
	var out []Field
	for _, f := range all {
		if want[f.Name] {
			out = append(out, f)
			delete(want, f.Name)
		}
	}
	if len(want) > 0 {
		return nil, fmt.Errorf("fields not in %s: %s", "the struct", strings.Join(sortedKeys(want), ", "))
	}
	return out, nil
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

// render produces the formatted snippet and the imports it needs.
func render(req Request) (string, []importSpec, *parsed, error) {
	items, err := List(req.Context)
	if err != nil {
		return "", nil, nil, err
	}
	found := false
	for _, item := range items {
		found = found || item.ID == req.Item
	}
	if !found {
		return "", nil, nil, fmt.Errorf("%q does not apply here", req.Item)
	}
	p, err := parse(req.Source, req.Package)
	if err != nil {
		return "", nil, nil, err
	}
	r := &renderer{names: importNames(p.file)}
	if req.Item == ItemTest { // the test goes to a new file that imports nothing yet
		r.names = map[string]string{}
	}
	data, err := itemData(req, p, r)
	if err != nil {
		return "", nil, nil, err
	}
	var buf bytes.Buffer
	if err := templates.ExecuteTemplate(&buf, req.Item, data); err != nil {
		return "", nil, nil, err
	}
	formatted, err := format.Source(buf.Bytes())
	if err != nil {
		return "", nil, nil, fmt.Errorf("generated code does not format: %w", err)
	}
	return strings.TrimSpace(string(formatted)), r.needs, p, nil
}

func itemData(req Request, p *parsed, r *renderer) (map[string]any, error) {
	recv := receiverName(req.Name)
	switch req.Item {
	case ItemConstructor, ItemOptions:
		fields, err := pick(req.Fields, req.Selected)
		if err != nil {
			return nil, err
		}
		views := fieldViews(fields)
		params := make([]string, len(views))
		for i, v := range views {
			params[i] = v.Param + " " + v.Type
		}
		return map[string]any{"Type": req.Name, "Recv": recv, "Fields": views, "Params": strings.Join(params, ", ")}, nil
	case ItemAccessors:
		fields, err := pick(req.Fields, req.Selected)
		if err != nil {
			return nil, err
		}
		type accessor struct {
			Field, Export, Param, FieldType string
			Getter, Setter                  bool
		}
		var list []accessor
		for _, f := range fields {
			if !isUnexported(f.Name) {
				continue
			}
			a := accessor{Field: f.Name, Export: exported(f.Name), Param: local(f.Name), FieldType: f.Type}
			if a.Param == recv {
				a.Param = "value"
			}
			a.Getter = !p.declared[req.Name+"."+a.Export]
			a.Setter = !p.declared[req.Name+".Set"+a.Export]
			if a.Getter || a.Setter {
				list = append(list, a)
			}
		}
		if len(list) == 0 {
			return nil, errors.New("no unexported field without accessors")
		}
		return map[string]any{"Type": req.Name, "Recv": recv, "Accessors": list}, nil
	case ItemString:
		fields, err := pick(req.Fields, req.Selected)
		if err != nil {
			return nil, err
		}
		if len(req.Selected) == 0 { // a lock or atomic cannot be passed to Sprintf by value
			kept := fields[:0:0]
			for _, f := range fields {
				if !strings.HasPrefix(f.Type, "sync.") && !strings.HasPrefix(f.Type, "atomic.") {
					kept = append(kept, f)
				}
			}
			fields = kept
		}
		parts := make([]string, len(fields))
		for i, f := range fields {
			parts[i] = f.Name + ": " + verb(f)
		}
		return map[string]any{"Type": req.Name, "Recv": recv, "Fmt": r.pkg("fmt"), "Fields": fieldViews(fields), "Layout": strings.Join(parts, ", ")}, nil
	case ItemErrorType:
		base, err := baseName(req.AskedName, "Error", p.file.Name.Name)
		if err != nil {
			return nil, err
		}
		return map[string]any{"Base": base, "Words": strings.ToLower(strings.Join(words(base), " ")), "Errors": r.pkg("errors")}, nil
	case ItemMain:
		return map[string]any{"Fmt": r.pkg("fmt"), "OS": r.pkg("os")}, nil
	case ItemHandler:
		base, err := baseName(req.AskedName, "Handler", "health")
		if err != nil {
			return nil, err
		}
		name := local(base) + "Handler"
		return map[string]any{"Name": name, "Route": strings.ToLower(strings.Join(words(base), " ")), "HTTP": r.pkg("net/http"), "IO": r.pkg("io")}, nil
	case ItemMock:
		return mockData(req, recv, r)
	case ItemTest:
		return testData(req, p, r)
	}
	return nil, fmt.Errorf("unknown item %q", req.Item)
}

// baseName turns the dialog's name into the exported base of a declaration: "parse" gives Parse; a trailing suffix is dropped.
func baseName(name, suffix, fallback string) (string, error) {
	if strings.TrimSpace(name) == "" {
		name = fallback
	}
	base := exported(strings.TrimSuffix(name, suffix))
	if !token.IsIdentifier(base) {
		return "", fmt.Errorf("%q is not a valid Go name", name)
	}
	return base, nil
}

func paramNames(params []Field) []string {
	names := make([]string, len(params))
	for i, p := range params {
		names[i] = p.Name
		if p.Name == "" || p.Name == "_" {
			names[i] = "p" + strconv.Itoa(i)
		}
	}
	return names
}

func mockData(req Request, recv string, r *renderer) (map[string]any, error) {
	type method struct {
		Name, Params, ParamTypes, ResultType, Return, Args string
	}
	var methods []method
	for _, m := range req.Methods {
		names := paramNames(m.Params)
		var params, types, args []string
		for i, p := range m.Params {
			params = append(params, names[i]+" "+p.Type)
			types = append(types, p.Type)
			arg := names[i]
			if strings.HasPrefix(p.Type, "...") {
				arg += "..."
			}
			args = append(args, arg)
		}
		result := ""
		switch len(m.Results) {
		case 0:
		case 1:
			result = " " + m.Results[0]
		default:
			result = " (" + strings.Join(m.Results, ", ") + ")"
		}
		ret := ""
		if len(m.Results) > 0 {
			ret = "return "
		}
		methods = append(methods, method{m.Name, strings.Join(params, ", "), strings.Join(types, ", "), result, ret, strings.Join(args, ", ")})
	}
	if len(methods) == 0 {
		return nil, errors.New("the interface has no methods to mock")
	}
	return map[string]any{"Type": req.Name, "Mock": "Mock" + exported(req.Name), "Recv": "m", "Methods": methods}, nil
}

func testData(req Request, p *parsed, r *renderer) (map[string]any, error) {
	type field struct{ Name, Type string }
	type value struct{ Got, Want string }
	taken := map[string]bool{"name": true, "want": true, "wantErr": true}
	var fields []field
	var args, types []string
	for i, name := range paramNames(req.Params) {
		typ := req.Params[i].Type
		if typ == "context.Context" {
			args = append(args, r.pkg("context")+".Background()")
			continue
		}
		field := field{Name: name, Type: typ}
		for taken[field.Name] || strings.HasPrefix(field.Name, "want") {
			field.Name += "Arg"
		}
		arg := "tt." + field.Name
		if strings.HasPrefix(typ, "...") {
			field.Type = "[]" + strings.TrimPrefix(typ, "...")
			arg += "..."
		}
		taken[field.Name] = true
		fields = append(fields, field)
		args = append(args, arg)
		types = append(types, typ)
	}
	hasErr := len(req.Results) > 0 && req.Results[len(req.Results)-1] == "error"
	count := len(req.Results)
	if hasErr {
		count--
	}
	var values []value
	var lhs []string
	for i := 0; i < count; i++ {
		got, want := "got", "want"
		if count > 1 {
			got, want = got+strconv.Itoa(i), want+strconv.Itoa(i)
		}
		lhs = append(lhs, got)
		values = append(values, value{got, want})
		fields = append(fields, field{want, req.Results[i]})
	}
	if hasErr {
		lhs = append(lhs, "err")
		fields = append(fields, field{"wantErr", "bool"})
	}
	call := req.Name + "(" + strings.Join(args, ", ") + ")"
	if req.Receiver != "" {
		call = "r." + call
	}
	if len(lhs) > 0 {
		call = strings.Join(lhs, ", ") + " := " + call
	}
	label := req.Name
	if req.Receiver != "" {
		label = req.Receiver + "." + req.Name
	}
	r.pkg("testing")
	reflectName := ""
	if len(values) > 0 {
		reflectName = r.pkg("reflect")
	}
	if err := copyImports(p, r, append(types, req.Results...)); err != nil {
		return nil, err
	}
	return map[string]any{
		"TestName": testName(req.Context), "Fields": fields, "Recv": req.Receiver, "Call": call,
		"HasErr": hasErr, "Values": values, "Reflect": reflectName, "Label": label,
	}, nil
}

// copyImports makes the new test file import the packages that the parameter and result types name, under the same
// names the source file uses.
func copyImports(p *parsed, r *renderer, types []string) error {
	fileNames := map[string]importSpec{}
	for _, spec := range p.file.Imports {
		importPath, _ := strconv.Unquote(spec.Path.Value)
		name := ""
		if spec.Name != nil {
			name = spec.Name.Name
		}
		local := name
		if local == "" {
			local = defaultName(importPath)
		}
		fileNames[local] = importSpec{Name: name, Path: importPath}
	}
	for _, typ := range types {
		expr, err := parser.ParseExpr(strings.TrimPrefix(typ, "..."))
		if err != nil {
			return fmt.Errorf("type %q does not parse: %w", typ, err)
		}
		ast.Inspect(expr, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok {
				if id, ok := sel.X.(*ast.Ident); ok {
					if spec, found := fileNames[id.Name]; found {
						r.use(spec)
					}
				}
			}
			return true
		})
	}
	return nil
}
