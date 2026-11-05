package langsvc

import (
	"strings"
	"testing"
)

func TestHeadings(t *testing.T) {
	tests := map[string]struct {
		document string
		want     []heading
	}{
		"atx levels":                          {"# A\n## B\n### C\n## D", []heading{{1, "A", 0}, {2, "B", 1}, {3, "C", 2}, {2, "D", 3}}},
		"closing hashes and spaces":           {"##   Title  ##  \n", []heading{{2, "Title", 0}}},
		"hashtag is not a heading":            {"#hashtag\ntext", nil},
		"seven hashes are not":                {"####### seven", nil},
		"up to three spaces indent":           {"   # ok\n    # code", []heading{{1, "ok", 0}}},
		"backtick fence is skipped":           {"```\n# not a heading\n```\n# real", []heading{{1, "real", 3}}},
		"tilde fence is skipped":              {"~~~go\n# nope\n~~~\n## yes", []heading{{2, "yes", 3}}},
		"fence needs a matching closer":       {"````\n```\n# still code\n````\n# out", []heading{{1, "out", 4}}},
		"unclosed fence swallows the rest":    {"# first\n```\n# code", []heading{{1, "first", 0}}},
		"setext h1 and h2":                    {"Title\n=====\n\nSub\n---\n", []heading{{1, "Title", 0}, {2, "Sub", 3}}},
		"rule after blank line is no heading": {"text\n\n---\n", nil},
		"empty heading is skipped":            {"#\n# x", []heading{{1, "x", 1}}},
		"windows line endings":                {"# A\r\n## B\r\n", []heading{{1, "A", 0}, {2, "B", 1}}},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			got := headings(test.document)
			if len(got) != len(test.want) {
				t.Fatalf("got %+v, want %+v", got, test.want)
			}
			for index := range got {
				if got[index] != test.want[index] {
					t.Fatalf("got %+v, want %+v", got, test.want)
				}
			}
		})
	}
}

func TestMarkdownSymbolsNestByLevelAndSpanTheirSection(t *testing.T) {
	document := "# One\ntext\n## Two\n### Three\n## Four\n# Five\n"
	symbols := markdownSymbols(document)
	if len(symbols) != 2 || symbols[0].Name != "One" || symbols[1].Name != "Five" {
		t.Fatalf("top level: %+v", symbols)
	}
	one := symbols[0]
	if len(one.Children) != 2 || one.Children[0].Name != "Two" || one.Children[1].Name != "Four" {
		t.Fatalf("One children: %+v", one.Children)
	}
	if len(one.Children[0].Children) != 1 || one.Children[0].Children[0].Name != "Three" {
		t.Fatalf("Two children: %+v", one.Children[0].Children)
	}
	if one.StartLine != 0 || one.EndLine != 4 {
		t.Fatalf("One must span lines 0..4 (up to the next h1), got %d..%d", one.StartLine, one.EndLine)
	}
	if one.Children[0].EndLine != 3 {
		t.Fatalf("Two ends where Four starts, got %d", one.Children[0].EndLine)
	}
	if symbols[1].EndLine != 5 {
		t.Fatalf("the last section runs to the last line, got %d", symbols[1].EndLine)
	}
}

func TestMarkdownSkippedLevelNestsUnderNearestParent(t *testing.T) {
	symbols := markdownSymbols("# A\n### C\n## B\n")
	if len(symbols) != 1 || len(symbols[0].Children) != 2 || symbols[0].Children[0].Name != "C" || symbols[0].Children[1].Name != "B" {
		t.Fatalf("got %+v", symbols)
	}
}

func TestRenderMarkdown(t *testing.T) {
	html := renderMarkdown("# Title\n\nsome **bold** text\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n")
	for _, want := range []string{"<h1", "Title", "<strong>bold</strong>", "<table>", `type="checkbox"`} {
		if !strings.Contains(html, want) {
			t.Errorf("preview misses %q:\n%s", want, html)
		}
	}
}

func TestRenderMarkdownDoesNotPassRawHTMLOrScriptLinks(t *testing.T) {
	html := renderMarkdown("<script>alert(1)</script>\n\n[x](javascript:alert(1))\n\n<img src=x onerror=alert(1)>\n")
	for _, forbidden := range []string{"<script", "javascript:", "onerror="} {
		if strings.Contains(strings.ToLower(html), forbidden) {
			t.Errorf("preview must not contain %q:\n%s", forbidden, html)
		}
	}
}
