package generate

import (
	"go/ast"
	"go/token"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// importSpec is one import: an optional alias and the path.
type importSpec struct{ Name, Path string }

func (s importSpec) text() string {
	if s.Name != "" {
		return s.Name + " " + strconv.Quote(s.Path)
	}
	return strconv.Quote(s.Path)
}

var versionSuffix = regexp.MustCompile(`^v[0-9]+$`)

// defaultName is the package name an import path gets when it has no alias.
func defaultName(importPath string) string {
	name := path.Base(importPath)
	if versionSuffix.MatchString(name) && strings.Contains(importPath, "/") {
		return path.Base(path.Dir(importPath))
	}
	return name
}

func isStd(importPath string) bool {
	first, _, _ := strings.Cut(importPath, "/")
	return !strings.Contains(first, ".")
}

// importNames maps import path to the name the file uses for it. Blank and dot imports cannot be used by generated code.
func importNames(file *ast.File) map[string]string {
	names := map[string]string{}
	for _, spec := range file.Imports {
		importPath, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			continue
		}
		switch {
		case spec.Name == nil:
			names[importPath] = defaultName(importPath)
		case spec.Name.Name != "_" && spec.Name.Name != ".":
			names[importPath] = spec.Name.Name
		}
	}
	return names
}

// importBlock writes a whole import declaration: the standard library first, then a blank line, then the rest.
func importBlock(specs []importSpec) string {
	sort.SliceStable(specs, func(i, j int) bool {
		si, sj := isStd(specs[i].Path), isStd(specs[j].Path)
		if si != sj {
			return si
		}
		return specs[i].Path < specs[j].Path
	})
	if len(specs) == 1 {
		return "import " + specs[0].text()
	}
	var b strings.Builder
	b.WriteString("import (\n")
	for i, s := range specs {
		if i > 0 && isStd(specs[i-1].Path) && !isStd(s.Path) {
			b.WriteString("\n")
		}
		b.WriteString("\t" + s.text() + "\n")
	}
	b.WriteString(")")
	return b.String()
}

// importEdits adds the imports the file lacks, by position in its AST so nothing else in the file is touched: into the
// import block next to its neighbours in sorted order, by replacing a one-line import, or after the package clause.
func importEdits(source string, fset *token.FileSet, file *ast.File, needs []importSpec) []byteEdit {
	if len(needs) == 0 {
		return nil
	}
	sort.SliceStable(needs, func(i, j int) bool { return needs[i].Path < needs[j].Path })
	var decl *ast.GenDecl
	for _, d := range file.Decls {
		if gen, ok := d.(*ast.GenDecl); ok && gen.Tok == token.IMPORT {
			decl = gen
			break
		}
	}
	tokenFile := fset.File(file.Pos())
	if decl == nil {
		offset := tokenFile.Offset(file.Name.End())
		if end := strings.IndexByte(source[offset:], '\n'); end >= 0 {
			offset += end
		} else {
			offset = len(source)
		}
		return []byteEdit{{offset, offset, "\n\n" + importBlock(needs)}}
	}
	if !decl.Lparen.IsValid() {
		all := append([]importSpec{}, needs...)
		for _, spec := range decl.Specs {
			is := spec.(*ast.ImportSpec)
			p, _ := strconv.Unquote(is.Path.Value)
			item := importSpec{Path: p}
			if is.Name != nil {
				item.Name = is.Name.Name
			}
			all = append(all, item)
		}
		return []byteEdit{{tokenFile.Offset(decl.Pos()), tokenFile.Offset(decl.End()), importBlock(all)}}
	}

	specs := make([]*ast.ImportSpec, len(decl.Specs))
	for i, s := range decl.Specs {
		specs[i] = s.(*ast.ImportSpec)
	}
	var groups [][]*ast.ImportSpec
	for i, s := range specs {
		if i > 0 && fset.Position(s.Pos()).Line-fset.Position(specs[i-1].End()).Line > 1 {
			groups = append(groups, nil)
		}
		if len(groups) == 0 {
			groups = append(groups, nil)
		}
		groups[len(groups)-1] = append(groups[len(groups)-1], s)
	}
	pathOf := func(s *ast.ImportSpec) string { p, _ := strconv.Unquote(s.Path.Value); return p }

	var out []byteEdit
	add := func(offset int, text string) {
		if n := len(out); n > 0 && out[n-1].start == offset {
			out[n-1].text += text
			return
		}
		out = append(out, byteEdit{offset, offset, text})
	}
	for _, need := range needs {
		var group []*ast.ImportSpec
		for _, g := range groups {
			if isStd(pathOf(g[0])) == isStd(need.Path) {
				group = g
				break
			}
		}
		if group == nil {
			add(tokenFile.Offset(decl.Rparen), "\n\t"+need.text()+"\n")
			continue
		}
		placed := false
		for _, s := range group {
			if pathOf(s) > need.Path {
				add(tokenFile.Offset(tokenFile.LineStart(fset.Position(s.Pos()).Line)), "\t"+need.text()+"\n")
				placed = true
				break
			}
		}
		if !placed {
			last := group[len(group)-1]
			add(tokenFile.Offset(tokenFile.LineStart(fset.Position(last.End()).Line+1)), "\t"+need.text()+"\n")
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].start < out[j].start })
	return out
}
