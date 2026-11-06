package generate

import (
	"strings"
	"testing"
)

func fmtString(t *testing.T, source string) string {
	t.Helper()
	result, err := Render(Request{Item: ItemString, Context: Context{
		Package: "demo", Source: source, Kind: KindStruct, Name: "T", Fields: []Field{{Name: "a", Type: "string"}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	out, err := ApplyEdits(source, result.Edits)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestImportIsAddedToAnExistingBlockInSortedPosition(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport (\n\t\"errors\"\n\t\"os\"\n\n\t\"example.com/x\"\n)\n\ntype T struct{ a string }\n\nvar _ = errors.New\nvar _ = os.Exit\nvar _ = x.Y\n")
	want := "import (\n\t\"errors\"\n\t\"fmt\"\n\t\"os\"\n\n\t\"example.com/x\"\n)\n"
	if !strings.Contains(out, want) {
		t.Errorf("got\n%s", out)
	}
}

func TestImportIsAddedAfterTheLastOfItsGroup(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport (\n\t\"errors\"\n\n\t\"example.com/x\"\n)\n\ntype T struct{ a string }\n\nvar _ = errors.New\nvar _ = x.Y\n")
	want := "import (\n\t\"errors\"\n\t\"fmt\"\n\n\t\"example.com/x\"\n)\n"
	if !strings.Contains(out, want) {
		t.Errorf("got\n%s", out)
	}
}

func TestImportBlockWithOnlyThirdPartyGetsANewStdGroup(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport (\n\t\"example.com/x\"\n)\n\ntype T struct{ a string }\n\nvar _ = x.Y\n")
	if !strings.Contains(out, "\t\"example.com/x\"\n\n\t\"fmt\"\n)") {
		t.Errorf("got\n%s", out)
	}
}

func TestImportIsCreatedWhenThereIsNoImportDeclaration(t *testing.T) {
	out := fmtString(t, "package demo\n\ntype T struct{ a string }\n")
	if !strings.HasPrefix(out, "package demo\n\nimport \"fmt\"\n\ntype T struct{ a string }\n\n// String implements") {
		t.Errorf("got\n%s", out)
	}
}

func TestSingleLineImportBecomesABlock(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport \"os\"\n\ntype T struct{ a string }\n\nvar _ = os.Exit\n")
	if !strings.Contains(out, "import (\n\t\"fmt\"\n\t\"os\"\n)\n") {
		t.Errorf("got\n%s", out)
	}
}

func TestAnAliasedImportIsReusedUnderItsAlias(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport (\n\tstr \"fmt\"\n)\n\ntype T struct{ a string }\n")
	if !strings.Contains(out, "str.Sprintf(") || strings.Contains(out, "fmt.Sprintf") || strings.Count(out, "\"fmt\"") != 1 {
		t.Errorf("got\n%s", out)
	}
}

func TestAnExistingImportIsNotDuplicated(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport \"fmt\"\n\ntype T struct{ a string }\n\nvar _ = fmt.Sprint\n")
	if strings.Count(out, "\"fmt\"") != 1 {
		t.Errorf("got\n%s", out)
	}
}

func TestBlankImportDoesNotCount(t *testing.T) {
	out := fmtString(t, "package demo\n\nimport _ \"fmt\"\n\ntype T struct{ a string }\n")
	if !strings.Contains(out, "fmt.Sprintf(") || strings.Count(out, "\"fmt\"") != 2 {
		t.Errorf("got\n%s", out)
	}
}

func TestEditsUseUTF16ColumnsAndApplyBack(t *testing.T) {
	source := "package demo // 😀 é\n\ntype T struct{ a string }\n"
	result, err := Render(Request{Item: ItemString, Context: Context{Package: "demo", Source: source, Kind: KindStruct, Name: "T", Fields: []Field{{Name: "a", Type: "string"}}}})
	if err != nil {
		t.Fatal(err)
	}
	// the import is inserted at the end of line 0: "package demo // " (16) + emoji (2 units) + " é" (2) = 20
	if e := result.Edits[0]; e.StartLine != 0 || e.StartChar != 20 {
		t.Errorf("first edit starts at %d:%d, want 0:20", e.StartLine, e.StartChar)
	}
	if _, err := ApplyEdits(source, result.Edits); err != nil {
		t.Fatal(err)
	}
}

func TestEmptyBufferBecomesOneEditThatWritesTheFile(t *testing.T) {
	result, err := Render(Request{Item: ItemMain, Context: Context{Package: "main", Kind: KindEmpty}})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Edits) != 1 || result.Edits[0].StartLine != 0 || !strings.HasPrefix(result.Edits[0].Text, "package main\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nfunc main()") {
		t.Errorf("edits = %+v", result.Edits)
	}
}

func TestRenderRefusesABufferThatDoesNotParse(t *testing.T) {
	_, err := Render(Request{Item: ItemString, Context: Context{Package: "demo", Source: "package demo\n\ntype T struct {", Kind: KindStruct, Name: "T", Fields: []Field{{Name: "a", Type: "string"}}}})
	if err == nil {
		t.Error("a broken buffer must fail")
	}
}
