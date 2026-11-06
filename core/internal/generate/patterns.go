package generate

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"text/template"
)

// Parameter kinds, as the dialog and the wire see them.
const (
	kindType      = "type"      // one Go name, written exported
	kindNames     = "names"     // a list of Go names
	kindSignature = "signature" // one method signature: Execute(ctx context.Context, in string) (string, error)
	kindFields    = "fields"    // a list of "name type"
	kindTypeExpr  = "typeexpr"  // one type expression: string, []byte, *http.Request
)

// patternDef is one design pattern: how it is offered, what it asks for and its template. The data a template sees is
// one entry per parameter key (see parseParam) plus header, modern (module Go version 1.23+), declared (names already in
// the package) and, for patterns with fields, r (a receiver name that no field parameter shadows).
type patternDef struct {
	ID, Title, Group, Detail string
	Note                     string // the simpler Go idiom, when there is one
	Params                   []ParamSpec
	Folder                   bool                                                                 // an Explorer item: offered for a folder, always written to a new file named after FileKey
	FileKey, FileSuffix      string                                                               // the answer that names the file (snake_case) and the suffix before .go
	Reserved                 map[string][]string                                                  // parameter key -> names it must not use
	Prepare                  func(req Request, p *parsed, r *renderer, data map[string]any) error // adds data from the file itself
	Tmpl                     string
}

// catalogue lists the patterns in the order of the Design Pattern submenu.
var catalogue = concat(creational, structural, behavioral)

func concat(groups ...[]patternDef) []patternDef {
	var all []patternDef
	for _, g := range groups {
		all = append(all, g...)
	}
	return all
}

func findPattern(id string) (patternDef, bool) {
	for _, d := range allDefs() {
		if d.ID == id {
			return d, true
		}
	}
	return patternDef{}, false
}

// allDefs is every definition a template exists for: the patterns, the folder items and Implement Interface.
func allDefs() []patternDef {
	return append(append([]patternDef{implementDef}, catalogue...), folderCatalogue...)
}

func patternItems() []Item {
	items := make([]Item, len(catalogue))
	for i, d := range catalogue {
		items[i] = Item{ID: d.ID, Title: d.Title, Detail: d.Detail, Group: d.Group, Params: d.Params}
	}
	return items
}

// header is the comment that names the pattern, links the reference and points at a simpler Go idiom when there is one.
func (d patternDef) header() string {
	if d.Folder {
		return ""
	}
	lines := []string{"// " + d.Title + " pattern: https://refactoring.guru/design-patterns/" + d.ID}
	if d.Note != "" {
		for i, line := range strings.Split(d.Note, "\n") {
			if i == 0 {
				line = "Simpler in Go: " + line
			}
			lines = append(lines, "// "+line)
		}
	}
	return strings.Join(lines, "\n")
}

var patternTemplates = func() *template.Template {
	root := template.New("").Funcs(template.FuncMap{
		"pkg":   func(string) string { return "" }, // replaced per render, it records the imports
		"local": local, "lower": strings.ToLower, "upper": strings.ToUpper, "snake": func(s string) string { return strings.ToLower(strings.Join(words(s), "_")) }, "fail": failTemplate, "recv": recv, "recvSig": recvSig, "stub": stub, "nextOf": nextOf,
		"isSlice": func(t string) bool { return strings.HasPrefix(t, "[]") },
		"isMap":   func(t string) bool { return strings.HasPrefix(t, "map[") },
	})
	for _, d := range allDefs() {
		template.Must(root.New(d.ID).Parse(d.Tmpl))
	}
	return root
}()

// renderPattern produces the formatted snippet and the imports of a pattern.
func renderPattern(def patternDef, req Request) (string, []importSpec, *parsed, error) {
	p, err := parse(req.Source, req.Package)
	if err != nil {
		return "", nil, nil, err
	}
	r := &renderer{names: importNames(p.file)}
	if req.Target == TargetFile || def.Folder { // a new file starts without imports
		r.names = map[string]string{}
	}
	data, err := def.data(req, p, r)
	if err != nil {
		return "", nil, nil, err
	}
	t, err := patternTemplates.Clone()
	if err != nil {
		return "", nil, nil, err
	}
	t.Funcs(template.FuncMap{"pkg": r.pkg})
	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, def.ID, data); err != nil {
		return "", nil, nil, err
	}
	formatted, err := format.Source(buf.Bytes())
	if err != nil {
		return "", nil, nil, fmt.Errorf("generated code does not format: %w", err)
	}
	snippet := strings.TrimSpace(string(formatted))
	if err := checkDeclarations(snippet, p.declared); err != nil {
		return "", nil, nil, err
	}
	return snippet, r.needs, p, nil
}

// checkDeclarations refuses a snippet that declares a name twice or one the package already has.
func checkDeclarations(snippet string, existing map[string]bool) error {
	file, err := parser.ParseFile(token.NewFileSet(), "", "package p\n\n"+snippet, 0)
	if err != nil {
		return fmt.Errorf("generated code does not parse: %w", err)
	}
	seen := map[string]bool{}
	for _, name := range declNames(file) {
		if name == "_" { // compile-time interface assertions
			continue
		}
		if seen[name] {
			return fmt.Errorf("%s is declared twice; give the parameters different names", name)
		}
		if existing[name] {
			return fmt.Errorf("%s is already declared in this package", name)
		}
		seen[name] = true
	}
	return nil
}

// data parses the answers of the dialog, falling back to each parameter's default.
func (d patternDef) data(req Request, p *parsed, r *renderer) (map[string]any, error) {
	known := map[string]bool{}
	for _, spec := range d.Params {
		known[spec.Key] = true
	}
	answers := map[string][]string{}
	for _, v := range req.Values {
		if !known[v.Key] {
			return nil, fmt.Errorf("unknown parameter %q for %s", v.Key, d.Title)
		}
		for _, value := range v.Values {
			if value = strings.TrimSpace(value); value != "" {
				answers[v.Key] = append(answers[v.Key], value)
			}
		}
	}
	data := map[string]any{"declared": p.declared, "modern": goAtLeast(req.GoVersion, 23), "header": d.header()}
	mainType := ""
	var fieldParams []string
	for _, spec := range d.Params {
		values := answers[spec.Key]
		if len(values) == 0 {
			values = spec.Default
		}
		if len(values) == 0 {
			return nil, fmt.Errorf("%s: needs an answer", spec.Label)
		}
		value, err := parseParam(spec, values, r)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", spec.Label, err)
		}
		for _, reserved := range d.Reserved[spec.Key] {
			for _, v := range values {
				if exported(v) == reserved {
					return nil, fmt.Errorf("%s: %q is reserved by the pattern", spec.Label, reserved)
				}
			}
		}
		switch v := value.(type) {
		case string:
			if spec.Kind == kindType && mainType == "" {
				mainType = v
			}
		case []fieldView:
			for _, f := range v {
				fieldParams = append(fieldParams, f.Param)
			}
		}
		data[spec.Key] = value
	}
	if fieldParams != nil {
		data["r"] = recv(mainType, fieldParams...)
	}
	if d.Prepare != nil {
		if err := d.Prepare(req, p, r, data); err != nil {
			return nil, err
		}
	}
	return data, nil
}

func parseParam(spec ParamSpec, values []string, r *renderer) (any, error) {
	if !spec.Multi && len(values) > 1 {
		return nil, fmt.Errorf("takes one value, got %d", len(values))
	}
	switch spec.Kind {
	case kindType:
		return goName(values[0])
	case kindNames:
		names := make([]string, len(values))
		seen := map[string]bool{}
		for i, v := range values {
			name, err := goName(v)
			if err != nil {
				return nil, err
			}
			if seen[name] {
				return nil, fmt.Errorf("%s is given twice", name)
			}
			seen[name], names[i] = true, name
		}
		return names, nil
	case kindSignature:
		return parseSignature(values[0], r)
	case kindFields:
		return parseFields(values, r)
	case kindTypeExpr:
		if err := checkType(values[0], r); err != nil {
			return nil, err
		}
		return values[0], nil
	}
	return nil, fmt.Errorf("unknown parameter kind %q", spec.Kind)
}

// goName turns what the user typed into an exported Go name: "fast strategy" is refused, "fast" gives Fast.
func goName(v string) (string, error) {
	name := exported(strings.TrimSpace(v))
	if !token.IsIdentifier(name) {
		return "", fmt.Errorf("%q is not a valid Go name", v)
	}
	return name, nil
}

// goAtLeast reports whether a module Go version ("1.23", "go1.24.1") is known and is at least 1.minor.
func goAtLeast(version string, minor int) bool {
	var major, got int
	if _, err := fmt.Sscanf(strings.TrimPrefix(version, "go"), "%d.%d", &major, &got); err != nil {
		return false
	}
	return major == 1 && got >= minor
}

// stdPackages are the packages a type or signature may name without the file importing them yet.
var stdPackages = map[string]string{
	"context": "context", "time": "time", "io": "io", "fmt": "fmt", "errors": "errors", "sync": "sync", "strings": "strings",
	"bytes": "bytes", "os": "os", "sort": "sort", "http": "net/http", "url": "net/url", "slog": "log/slog",
	"atomic": "sync/atomic", "json": "encoding/json", "sql": "database/sql",
}

// qualify makes sure every package a type or signature names (pkg.Name) is imported, adding the import when the file lacks it.
func (r *renderer) qualify(node ast.Node) error {
	var err error
	ast.Inspect(node, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok || err != nil {
			return err == nil
		}
		id, ok := sel.X.(*ast.Ident)
		if !ok {
			return true
		}
		for _, name := range r.names {
			if name == id.Name {
				return true
			}
		}
		path, ok := stdPackages[id.Name]
		switch {
		case !ok:
			err = fmt.Errorf("unknown package %q: import it in the file first", id.Name)
		case r.names[path] != "" && r.names[path] != id.Name:
			err = fmt.Errorf("package %s is imported as %s in this file", id.Name, r.names[path])
		default:
			r.pkg(path)
		}
		return err == nil
	})
	return err
}

func checkType(text string, r *renderer) error {
	expr, err := parser.ParseExpr(text)
	if err != nil {
		return fmt.Errorf("%q is not a type", text)
	}
	return r.qualify(expr)
}

// parseFields reads "name type" entries into struct fields.
func parseFields(values []string, r *renderer) ([]fieldView, error) {
	var out []fieldView
	seen := map[string]bool{}
	for _, v := range values {
		name, typ, ok := strings.Cut(v, " ")
		typ = strings.TrimSpace(typ)
		if !ok || typ == "" {
			return nil, fmt.Errorf("%q needs a name and a type", v)
		}
		if !token.IsIdentifier(name) {
			return nil, fmt.Errorf("%q is not a valid Go name", name)
		}
		if err := checkType(typ, r); err != nil {
			return nil, err
		}
		if seen[name] {
			return nil, fmt.Errorf("%s is given twice", name)
		}
		seen[name] = true
		out = append(out, fieldView{Name: name, Param: local(name), Type: typ, Export: exported(name)})
	}
	return out, nil
}

// sigView is a method signature ready for templates.
type sigView struct {
	Name    string
	Params  string // name type, name type
	Results string // "", "T" or "(T, U)"
	Args    string // name, name... (what a forwarding call passes)
	Ret     string // "return " when there are results
	Stub    string // named results for a stub body: "(r0 T, r1 U)", or ""
	names   []string
}

// parseSignature reads one interface method: Execute(ctx context.Context, in string) (string, error).
func parseSignature(text string, r *renderer) (sigView, error) {
	bad := fmt.Errorf("%q is not a method signature", text)
	src := "package p\n\ntype I interface {\n" + text + "\n}\n"
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "", src, 0)
	if err != nil || len(file.Decls) != 1 {
		return sigView{}, bad
	}
	iface, ok := file.Decls[0].(*ast.GenDecl).Specs[0].(*ast.TypeSpec).Type.(*ast.InterfaceType)
	if !ok || len(iface.Methods.List) != 1 || len(iface.Methods.List[0].Names) != 1 {
		return sigView{}, bad
	}
	method := iface.Methods.List[0]
	fn, ok := method.Type.(*ast.FuncType)
	if !ok {
		return sigView{}, bad
	}
	if err := r.qualify(fn); err != nil {
		return sigView{}, err
	}
	typeText := func(n ast.Node) string { return src[fset.Position(n.Pos()).Offset:fset.Position(n.End()).Offset] }
	sig := sigView{Name: method.Names[0].Name}
	var params, args []string
	for _, f := range fn.Params.List {
		if len(f.Names) == 0 {
			return sigView{}, fmt.Errorf("name every parameter of %q", text)
		}
		_, variadic := f.Type.(*ast.Ellipsis)
		for _, n := range f.Names {
			params = append(params, n.Name+" "+typeText(f.Type))
			arg := n.Name
			if variadic {
				arg += "..."
			}
			args = append(args, arg)
			sig.names = append(sig.names, n.Name)
		}
	}
	var results []string
	if fn.Results != nil {
		for _, f := range fn.Results.List {
			for range max(1, len(f.Names)) {
				results = append(results, typeText(f.Type))
			}
		}
	}
	sig.Params, sig.Args = strings.Join(params, ", "), strings.Join(args, ", ")
	switch len(results) {
	case 0:
	case 1:
		sig.Results = results[0]
	default:
		sig.Results = "(" + strings.Join(results, ", ") + ")"
	}
	if len(results) > 0 {
		sig.Ret = "return "
		named := make([]string, len(results))
		for i, res := range results {
			named[i] = fmt.Sprintf("r%d %s", i, res)
		}
		sig.Stub = "(" + strings.Join(named, ", ") + ")"
	}
	return sig, nil
}

// recv is the receiver name for a type: its first letter in lower case, lengthened until no taken name matches.
func recv(typ string, taken ...string) string {
	name := receiverName(typ)
	for contains(taken, name) {
		name += "x"
	}
	return name
}

func recvSig(typ string, sig sigView) string { return recv(typ, sig.names...) }

func contains(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}

// stub is a method that satisfies iface and leaves the body to the user: named results and a bare return.
func stub(typ, iface string, sig sigView) string {
	body := "\t// TODO: implement " + sig.Name + ".\n"
	if sig.Stub != "" {
		body += "\treturn\n"
	}
	return fmt.Sprintf("// %s implements %s.\nfunc (%s *%s) %s(%s) %s {\n%s}",
		sig.Name, iface, recvSig(typ, sig), typ, sig.Name, sig.Params, sig.Stub, body)
}

// nextOf is the element after i, wrapping around.
func nextOf(list []string, i int) string { return list[(i+1)%len(list)] }

// patternResult places a rendered pattern: into the current file, or into a new <pattern>.go next to it.
func patternResult(def patternDef, req Request, result Result, needs []importSpec, p *parsed) (Result, error) {
	if def.Folder {
		return folderResult(def, req, result, needs)
	}
	dir, current := filepath.Dir(req.Path), true
	if fi, err := osStat(req.Path); err == nil && fi.IsDir() {
		dir, current = req.Path, false
	}
	if req.Target != TargetFile {
		if !current {
			return Result{}, fmt.Errorf("%s is a folder: choose a new file to write the pattern into", filepath.Base(req.Path))
		}
		edits, err := insert(p, req.Context, result.Text, needs)
		if err != nil {
			return Result{}, err
		}
		result.Edits = edits
		return result, nil
	}
	target := filepath.Join(dir, strings.ReplaceAll(def.ID, "-", "_")+".go")
	if _, err := osStat(target); err == nil {
		return Result{}, fmt.Errorf("%s already exists; insert the pattern into the current file instead", filepath.Base(target))
	}
	content, err := insert(nil, Context{Package: patternPackage(req, p, dir)}, result.Text, needs)
	if err != nil {
		return Result{}, err
	}
	result.Files = []File{{Path: target, Content: content[0].Text}}
	return result, nil
}

// patternPackage is the package of a new file: the file's, or the folder's name when the folder has no Go file yet.
func patternPackage(req Request, p *parsed, dir string) string {
	if req.Package != "" {
		return req.Package
	}
	if strings.TrimSpace(req.Source) != "" {
		return p.file.Name.Name
	}
	if name := filepath.Base(dir); token.IsIdentifier(name) {
		return name
	}
	return "main"
}
