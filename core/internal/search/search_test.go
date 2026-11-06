package search

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func find(t *testing.T, root string, o Options) Result {
	t.Helper()
	r, err := Search(context.Background(), root, o)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestLiteralSearchFindsEveryOccurrenceWithPositions(t *testing.T) {
	root := tree(t, map[string]string{"a.go": "sum := 0\nfor { sum += 1 }\n", "sub/b.go": "return sum\n"})
	r := find(t, root, Options{Query: "sum"})
	if len(r.Matches) != 3 || r.Files != 2 {
		t.Fatalf("matches = %+v files = %d", r.Matches, r.Files)
	}
	want := []Match{{Path: "a.go", Line: 0, Start: 0, End: 3}, {Path: "a.go", Line: 1, Start: 6, End: 9}, {Path: "sub/b.go", Line: 0, Start: 7, End: 10}}
	for i, w := range want {
		g := r.Matches[i]
		if g.Path != w.Path || g.Line != w.Line || g.Start != w.Start || g.End != w.End {
			t.Errorf("match %d = %+v, want %+v", i, g, w)
		}
	}
	if r.Matches[1].Text != "for { sum += 1 }" {
		t.Errorf("text = %q", r.Matches[1].Text)
	}
}

func TestOptionsCaseWordAndRegex(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": "Sum sum summary SUM\nfoo123 foo45\n"})
	if r := find(t, root, Options{Query: "sum"}); len(r.Matches) != 4 {
		t.Errorf("case-insensitive by default: %d", len(r.Matches))
	}
	if r := find(t, root, Options{Query: "sum", CaseSensitive: true}); len(r.Matches) != 2 {
		t.Errorf("case-sensitive: %d", len(r.Matches))
	}
	if r := find(t, root, Options{Query: "sum", WholeWord: true}); len(r.Matches) != 3 {
		t.Errorf("whole word: %d", len(r.Matches))
	}
	r := find(t, root, Options{Query: `foo(\d+)`, Regex: true, HasReplace: true, Replacement: "bar-$1"})
	if len(r.Matches) != 2 || r.Matches[0].Replacement != "bar-123" || r.Matches[1].Replacement != "bar-45" {
		t.Errorf("regex replacement = %+v", r.Matches)
	}
	lit := find(t, root, Options{Query: "foo123", HasReplace: true, Replacement: "$1 stays"})
	if lit.Matches[0].Replacement != "$1 stays" {
		t.Errorf("a literal search replaces with the literal text: %q", lit.Matches[0].Replacement)
	}
}

func TestColumnsAreUTF16(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": "😀 café sum\n"})
	m := find(t, root, Options{Query: "sum"}).Matches[0]
	// 😀 is two UTF-16 units, then " café " is six
	if m.Start != 8 || m.End != 11 {
		t.Errorf("columns = %d..%d, want 8..11", m.Start, m.End)
	}
}

func TestIncludeGlobsAndSkippedFiles(t *testing.T) {
	big := strings.Repeat("sum\n", 700_000) // over 2 MB
	root := tree(t, map[string]string{
		"a.go": "sum\n", "b.md": "sum\n", ".git/config": "sum\n", "node_modules/x/y.js": "sum\n", ".hidden/z.go": "sum\n", "bin.dat": "sum\x00sum", "big.txt": big,
	})
	r := find(t, root, Options{Query: "sum"})
	got := map[string]bool{}
	for _, m := range r.Matches {
		got[m.Path] = true
	}
	if len(got) != 2 || !got["a.go"] || !got["b.md"] {
		t.Errorf("files searched = %v (skip .git, node_modules, hidden folders, binary and big files)", got)
	}
	if r.Skipped < 2 {
		t.Errorf("skipped = %d, want the binary and the big file counted", r.Skipped)
	}
	only := find(t, root, Options{Query: "sum", Include: []string{"*.go"}})
	if len(only.Matches) != 1 || only.Matches[0].Path != "a.go" {
		t.Errorf("include *.go = %+v", only.Matches)
	}
}

func TestAnIgnoredFileInAGitRepositoryIsSkipped(t *testing.T) {
	root := tree(t, map[string]string{"a.go": "sum\n", "gen/out.go": "sum\n", ".gitignore": "gen/\n"})
	if err := runGit(root, "init", "-q"); err != nil {
		t.Skip("git is not available")
	}
	r := find(t, root, Options{Query: "sum"})
	for _, m := range r.Matches {
		if strings.HasPrefix(m.Path, "gen/") {
			t.Errorf("an ignored folder was searched: %+v", m)
		}
	}
	if len(r.Matches) != 1 {
		t.Errorf("matches = %+v", r.Matches)
	}
}

func TestTooManyResultsAreCutOff(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": strings.Repeat("sum\n", 50)})
	r := find(t, root, Options{Query: "sum", MaxResults: 10})
	if len(r.Matches) != 10 || !r.Truncated {
		t.Errorf("got %d truncated=%v", len(r.Matches), r.Truncated)
	}
}

func TestBadInputIsRefused(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": "x\n"})
	for name, o := range map[string]Options{"empty": {Query: ""}, "bad regex": {Query: "(", Regex: true}, "huge query": {Query: strings.Repeat("a", 5000)}} {
		if _, err := Search(context.Background(), root, o); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := Search(context.Background(), "relative/dir", Options{Query: "x"}); err == nil {
		t.Error("a relative root must be refused")
	}
}

func TestLongLinesAreShortenedAroundTheMatch(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": strings.Repeat("x", 2000) + "sum" + strings.Repeat("y", 2000) + "\n"})
	m := find(t, root, Options{Query: "sum"}).Matches[0]
	if len(m.Text) > 500 || !strings.Contains(m.Text, "sum") {
		t.Errorf("text length %d: %.40q", len(m.Text), m.Text)
	}
	if m.Start != 2000 {
		t.Errorf("columns refer to the whole line: %d", m.Start)
	}
}

func TestCancellationStopsTheSearch(t *testing.T) {
	root := tree(t, map[string]string{"a.txt": "sum\n"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Search(ctx, root, Options{Query: "sum"}); err == nil {
		t.Error("a cancelled search must report it")
	}
}
