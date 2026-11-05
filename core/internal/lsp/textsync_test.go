package lsp

import "testing"

func change(startLine, startChar, endLine, endChar int, text string) contentChange {
	return contentChange{
		Range: &lspRange{
			Start: position{Line: startLine, Character: startChar},
			End:   position{Line: endLine, Character: endChar},
		},
		Text: text,
	}
}

func TestApplyChange(t *testing.T) {
	tests := map[string]struct {
		before string
		edit   contentChange
		want   string
	}{
		"full replace when no range":     {"old", contentChange{Text: "new"}, "new"},
		"insert at start":                {"bc", change(0, 0, 0, 0, "a"), "abc"},
		"insert at end of line":          {"ab\ncd", change(0, 2, 0, 2, "X"), "abX\ncd"},
		"replace within a line":          {"hello world", change(0, 6, 0, 11, "gopher"), "hello gopher"},
		"delete across lines":            {"one\ntwo\nthree", change(0, 1, 2, 2, ""), "oree"},
		"insert a newline":               {"ab", change(0, 1, 0, 1, "\n"), "a\nb"},
		"append after last line":         {"ab\n", change(1, 0, 1, 0, "cd"), "ab\ncd"},
		"two-byte rune counts as one":    {"é=1", change(0, 1, 0, 2, ":"), "é:1"},
		"emoji counts as two utf16":      {"a😀b", change(0, 3, 0, 4, "X"), "a😀X"},
		"edit before emoji":              {"a😀b", change(0, 1, 0, 3, ""), "ab"},
		"character past end clamps":      {"ab", change(0, 99, 0, 99, "!"), "ab!"},
		"line past end clamps to end":    {"ab", change(9, 0, 9, 0, "!"), "ab!"},
		"CRLF keeps the carriage return": {"a\r\nb", change(1, 0, 1, 1, "c"), "a\r\nc"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			if got := applyChange(test.before, test.edit); got != test.want {
				t.Fatalf("applyChange(%q) = %q, want %q", test.before, got, test.want)
			}
		})
	}
}

func TestDocStoreTracksOpenChangeClose(t *testing.T) {
	docs := newDocStore()
	docs.open("file:///a.go", "go", 1, "package a", 7)
	if !docs.change("file:///a.go", 2, []contentChange{change(0, 8, 0, 9, "b")}) {
		t.Fatal("change on an open doc must succeed")
	}
	snapshot := docs.snapshot()
	if len(snapshot) != 1 || snapshot[0].Text != "package b" || snapshot[0].Version != 2 || snapshot[0].LanguageID != "go" {
		t.Fatalf("snapshot %+v", snapshot)
	}
	if docs.change("file:///missing.go", 1, nil) {
		t.Fatal("change on an unknown doc must report false")
	}
	if last := docs.close("file:///a.go", 7); !last {
		t.Fatal("closing the only owner must report last=true")
	}
	if len(docs.snapshot()) != 0 {
		t.Fatal("closed doc must be gone")
	}
}

func TestDocStoreSharedBetweenOwners(t *testing.T) {
	docs := newDocStore()
	if first := docs.open("file:///a.go", "go", 1, "x", 1); !first {
		t.Fatal("first open must report first=true")
	}
	if first := docs.open("file:///a.go", "go", 1, "x", 2); first {
		t.Fatal("second owner must not report first=true")
	}
	if last := docs.close("file:///a.go", 1); last {
		t.Fatal("doc still has an owner")
	}
	if last := docs.close("file:///a.go", 2); !last {
		t.Fatal("last owner closing must report last=true")
	}
}

func TestDocStoreDropOwner(t *testing.T) {
	docs := newDocStore()
	docs.open("file:///a.go", "go", 1, "x", 1)
	docs.open("file:///b.go", "go", 1, "y", 1)
	docs.open("file:///b.go", "go", 1, "y", 2)
	closed := docs.dropOwner(1)
	if len(closed) != 1 || closed[0] != "file:///a.go" {
		t.Fatalf("only the doc nobody else owns is closed, got %v", closed)
	}
}
