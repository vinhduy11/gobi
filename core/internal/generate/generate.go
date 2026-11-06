// Package generate builds the code that Generate… inserts: constructors, accessors, String(), error types, functional
// options, table-driven tests, main(), HTTP handlers and mocks. It works on facts the UI sends (file, caret, symbol and
// its fields) and answers with the final text: the snippet is rendered with text/template, formatted with go/format and
// the import block is edited through go/ast, so applying the edits is one undo step and needs no LSP round trip.
package generate

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
)

// Symbol kinds the UI reports for the caret.
const (
	KindStruct    = "struct"
	KindInterface = "interface"
	KindFunc      = "func"
	KindFile      = "file"  // a file with code, caret outside any declaration
	KindEmpty     = "empty" // an empty file (or only a package clause)
)

// Item ids.
const (
	ItemConstructor = "constructor"
	ItemAccessors   = "accessors"
	ItemString      = "string"
	ItemErrorType   = "error-type"
	ItemOptions     = "options"
	ItemTest        = "test"
	ItemMain        = "main"
	ItemHandler     = "http-handler"
	ItemMock        = "mock"
)

// Field is a struct field, or a parameter of a function or method.
type Field struct {
	Name       string
	Type       string // source text of the type, as written in the file
	Underlying string // underlying basic type when the UI knows it ("string" for a named string type); may be empty
}

// Method is an interface method.
type Method struct {
	Name    string
	Params  []Field
	Results []string
}

// Context is what the UI knows about the caret.
type Context struct {
	Path     string // absolute path of the file
	Package  string
	Source   string // the live buffer text
	Line     int    // caret, 0-based
	Col      int
	Kind     string
	Name     string // symbol name under the caret
	Fields   []Field
	Methods  []Method
	Params   []Field  // func: parameters
	Results  []string // func: result types
	Receiver string   // func: receiver type name without the star; empty for a plain function
}

// Request asks for one item (Render, Preview) or for the list (List). Version is the buffer version the facts came from.
type Request struct {
	Context
	Version   uint64
	Item      string
	Selected  []string // fields the user ticked; empty means the item's default
	AskedName string   // extra name asked by the dialog (error type, handler)
	GoVersion string   // Go version of the module ("1.23", "go1.23.4"); empty when unknown
	Values    []ParamValue
	Target    string // TargetCurrent (default) or TargetFile, for the design patterns
}

// Where a design pattern is written.
const (
	TargetCurrent = "current" // into the current file, after the declaration at the caret
	TargetFile    = "file"    // into a new <pattern>.go in the package
)

// ParamValue is the answer to one pattern parameter; a blank answer means the default.
type ParamValue struct {
	Key    string
	Values []string
}

// ParamSpec describes one parameter a pattern asks for.
type ParamSpec struct {
	Key, Label string
	Kind       string // "type", "names", "signature", "fields" or "typeexpr"
	Default    []string
	Multi      bool // the dialog shows a list
}

// Item is one entry of the Generate popup.
type Item struct {
	ID, Title, Detail string
	NeedsName         bool        // the dialog asks for a name
	NeedsFields       bool        // the dialog lets the user tick fields
	Group             string      // design patterns: creational, structural or behavioral
	Params            []ParamSpec // design patterns: what the dialog asks
}

// File is a file to create.
type File struct{ Path, Content string }

// Result is the answer to Preview and Render. Version is the request's, echoed so the UI can drop a stale reply.
type Result struct {
	Version uint64
	Text    string   // the inserted code, formatted (for the preview)
	Imports []string // import paths the edit adds
	Edits   []Edit   // edits of the current file, ranges in the original text
	Files   []File   // files to create
}

// parsed is the source of a request, parsed once.
type parsed struct {
	fset     *token.FileSet
	file     *ast.File
	source   string
	declared map[string]bool
}

func parse(source, pkg string) (*parsed, error) {
	if strings.TrimSpace(source) == "" {
		if pkg == "" {
			pkg = "main"
		}
		source = "package " + pkg + "\n"
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "", source, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("the buffer does not parse: %w", err)
	}
	p := &parsed{fset: fset, file: file, source: source, declared: map[string]bool{}}
	for _, name := range declNames(file) {
		p.declared[name] = true
	}
	return p, nil
}

// declNames lists the top-level names of a file: functions and types as "Name", methods as "Type.Name", vars and consts.
func declNames(file *ast.File) []string {
	var names []string
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Recv != nil && len(d.Recv.List) == 1 {
				names = append(names, typeName(d.Recv.List[0].Type)+"."+d.Name.Name)
			} else {
				names = append(names, d.Name.Name)
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					names = append(names, s.Name.Name)
				case *ast.ValueSpec:
					for _, n := range s.Names {
						names = append(names, n.Name)
					}
				}
			}
		}
	}
	return names
}

func typeName(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.StarExpr:
		return typeName(e.X)
	case *ast.IndexExpr:
		return typeName(e.X)
	case *ast.IndexListExpr:
		return typeName(e.X)
	case *ast.Ident:
		return e.Name
	}
	return ""
}

func namedFields(fields []Field) []Field {
	var out []Field
	for _, f := range fields {
		if f.Name != "" && f.Name != "_" {
			out = append(out, f)
		}
	}
	return out
}

func testName(c Context) string {
	if c.Receiver != "" {
		return "Test" + c.Receiver + "_" + exported(c.Name)
	}
	return "Test" + exported(c.Name)
}

// List returns the items that apply to the context.
func List(ctx Context) ([]Item, error) {
	p, err := parse(ctx.Source, ctx.Package)
	if err != nil {
		return nil, err
	}
	var items []Item
	add := func(item Item) { items = append(items, item) }
	switch ctx.Kind {
	case KindStruct:
		fields := namedFields(ctx.Fields)
		if ctx.Name == "" || len(fields) == 0 {
			break
		}
		constructor := "New" + exported(ctx.Name)
		if !p.declared[constructor] {
			add(Item{ID: ItemConstructor, Title: "Constructor", Detail: constructor, NeedsFields: true})
			add(Item{ID: ItemOptions, Title: "Functional options", Detail: constructor + "(opts ...)", NeedsFields: true})
		}
		if first, ok := firstMissingAccessor(p, ctx.Name, fields); ok {
			add(Item{ID: ItemAccessors, Title: "Getters and Setters…", Detail: exported(first) + "() · Set" + exported(first) + "()", NeedsFields: true})
		}
		if !p.declared[ctx.Name+".String"] {
			add(Item{ID: ItemString, Title: "String() method", Detail: "String()", NeedsFields: true})
		}
		add(errorTypeItem())
	case KindInterface:
		if mock := "Mock" + exported(ctx.Name); ctx.Name != "" && !p.declared[mock] {
			add(Item{ID: ItemMock, Title: "Mock of Interface…", Detail: mock})
		}
	case KindFunc:
		if name := testName(ctx); ctx.Name != "" && !strings.HasSuffix(ctx.Path, "_test.go") && !p.declared[name] {
			add(Item{ID: ItemTest, Title: "Test for " + ctx.Name, Detail: name})
		}
	case KindEmpty, KindFile:
		if (ctx.Kind == KindEmpty && (ctx.Package == "main" || ctx.Package == "")) ||
			(ctx.Kind == KindFile && ctx.Package == "main" && !p.declared["main"]) {
			add(Item{ID: ItemMain, Title: "main() function", Detail: "main()"})
		}
		add(Item{ID: ItemHandler, Title: "HTTP handler…", Detail: "func(w http.ResponseWriter, r *http.Request)", NeedsName: true})
		add(errorTypeItem())
		items = append(items, patternItems()...)
	}
	return items, nil
}

func errorTypeItem() Item {
	return Item{ID: ItemErrorType, Title: "Error type…", Detail: "XxxError, ErrXxx", NeedsName: true}
}

// firstMissingAccessor reports the first unexported field that lacks a getter or a setter.
func firstMissingAccessor(p *parsed, typ string, fields []Field) (string, bool) {
	for _, f := range fields {
		if isUnexported(f.Name) && (!p.declared[typ+"."+exported(f.Name)] || !p.declared[typ+".Set"+exported(f.Name)]) {
			return f.Name, true
		}
	}
	return "", false
}

// Preview renders the item without building edits: the code the dialog shows.
func Preview(req Request) (Result, error) {
	snippet, needs, _, err := render(req)
	if err != nil {
		return Result{}, err
	}
	return Result{Version: req.Version, Text: snippet, Imports: importPaths(needs)}, nil
}

// Render returns the edits (and files) that insert the item.
func Render(req Request) (Result, error) {
	snippet, needs, p, err := render(req)
	if err != nil {
		return Result{}, err
	}
	result := Result{Version: req.Version, Text: snippet, Imports: importPaths(needs)}
	if def, ok := findPattern(req.Item); ok {
		return patternResult(def, req, result, needs, p)
	}
	if req.Item == ItemTest {
		target := strings.TrimSuffix(req.Path, ".go") + "_test.go"
		if _, err := osStat(target); err == nil {
			return Result{}, fmt.Errorf("%s already exists; add the test there by hand", filepath.Base(target))
		}
		content, err := insert(nil, Context{Package: req.Package}, snippet, needs)
		if err != nil {
			return Result{}, err
		}
		result.Files = []File{{Path: target, Content: content[0].Text}}
		return result, nil
	}
	edits, err := insert(p, req.Context, snippet, needs)
	if err != nil {
		return Result{}, err
	}
	result.Edits = edits
	return result, nil
}

func importPaths(needs []importSpec) []string {
	var out []string
	for _, n := range needs {
		out = append(out, n.Path)
	}
	return out
}

// insert builds the edits: the snippet after the declaration the caret is in (or at the end of the file), plus the import
// edit. A source with nothing in it becomes one edit that writes the whole file.
func insert(p *parsed, ctx Context, snippet string, needs []importSpec) ([]Edit, error) {
	blank := p == nil || strings.TrimSpace(ctx.Source) == ""
	if blank {
		var err error
		if p, err = parse("", ctx.Package); err != nil {
			return nil, err
		}
	}
	source := p.source
	at, text := len(source), "\n\n"+snippet+"\n"
	if strings.HasSuffix(source, "\n") {
		text = "\n" + snippet + "\n"
	}
	if ctx.Kind == KindStruct || ctx.Kind == KindInterface {
		end, ok := p.declEnd(ctx.Name)
		if !ok {
			return nil, fmt.Errorf("declaration %s is not in the buffer", ctx.Name)
		}
		at, text = end, "\n\n"+snippet
	}
	edits := append(importEdits(source, p.fset, p.file, needs), byteEdit{at, at, text})
	out := toEdits(source, edits)
	applied, err := ApplyEdits(source, out)
	if err != nil {
		return nil, err
	}
	if _, err := parse(applied, ""); err != nil {
		return nil, err
	}
	if blank {
		return []Edit{{Text: applied}}, nil
	}
	return out, nil
}

func (p *parsed) declEnd(name string) (int, bool) {
	tokenFile := p.fset.File(p.file.Pos())
	for _, decl := range p.file.Decls {
		if gen, ok := decl.(*ast.GenDecl); ok && gen.Tok == token.TYPE {
			for _, spec := range gen.Specs {
				if spec.(*ast.TypeSpec).Name.Name == name {
					return tokenFile.Offset(gen.End()), true
				}
			}
		}
	}
	return 0, false
}
