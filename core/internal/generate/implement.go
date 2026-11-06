package generate

import (
	"fmt"
	"go/ast"
	"strings"
)

// ItemImplement is Generate > Implement Interface…: method stubs for an interface declared in the same file. gopls offers
// this only as a quick fix for an existing type error, so Gobi renders it itself (see docs/implement/generate.md).
const ItemImplement = "implement"

var implementDef = patternDef{
	ID: ItemImplement, Title: "Implement Interface…",
	Detail: "method stubs for an interface declared in this file",
	Params: []ParamSpec{{Key: "interface", Label: "Interface", Kind: kindType}},
	Tmpl: `var _ {{.interface}} = (*{{.type}})(nil)
{{range .sigs}}
{{stub $.type $.interface .}}
{{end}}`,
	Prepare: implementPrepare,
}

// implementItem is the popup entry for a struct, or false when the file declares no interface.
func implementItem(p *parsed) (Item, bool) {
	names := interfaceNames(p)
	if len(names) == 0 {
		return Item{}, false
	}
	item := Item{ID: implementDef.ID, Title: implementDef.Title, Detail: implementDef.Detail, Params: append([]ParamSpec{}, implementDef.Params...)}
	item.Params[0].Default = []string{names[0]}
	return item, true
}

func interfaceNames(p *parsed) []string {
	var names []string
	for _, decl := range p.file.Decls {
		if gen, ok := decl.(*ast.GenDecl); ok {
			for _, spec := range gen.Specs {
				if ts, ok := spec.(*ast.TypeSpec); ok {
					if _, isInterface := ts.Type.(*ast.InterfaceType); isInterface {
						names = append(names, ts.Name.Name)
					}
				}
			}
		}
	}
	return names
}

// interfaceMethods returns the source text of each method of an interface declared in the file: Name(params) results.
func interfaceMethods(p *parsed, name string) ([]string, error) {
	file := p.fset.File(p.file.Pos())
	for _, decl := range p.file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gen.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok || ts.Name.Name != name {
				continue
			}
			iface, ok := ts.Type.(*ast.InterfaceType)
			if !ok {
				return nil, fmt.Errorf("%s is not an interface", name)
			}
			var methods []string
			for _, m := range iface.Methods.List {
				if _, isFunc := m.Type.(*ast.FuncType); !isFunc || len(m.Names) != 1 {
					return nil, fmt.Errorf("%s embeds another interface; list its methods there or implement it by hand", name)
				}
				methods = append(methods, p.source[file.Offset(m.Names[0].Pos()):file.Offset(m.Type.End())])
			}
			return methods, nil
		}
	}
	return nil, fmt.Errorf("interface %s is not declared in this file", name)
}

func implementPrepare(req Request, p *parsed, r *renderer, data map[string]any) error {
	iface := data["interface"].(string)
	texts, err := interfaceMethods(p, iface)
	if err != nil {
		return err
	}
	var sigs []sigView
	for _, text := range texts {
		name, _, _ := strings.Cut(text, "(")
		if p.declared[req.Name+"."+name] {
			continue // the type already has it
		}
		sig, err := parseSignature(text, r)
		if err != nil {
			return err
		}
		sigs = append(sigs, sig)
	}
	if len(sigs) == 0 {
		return fmt.Errorf("%s already has every method of %s", req.Name, iface)
	}
	data["type"], data["sigs"] = req.Name, sigs
	return nil
}
