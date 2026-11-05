package lsp

import "testing"

func TestApplyChangeUsesAllThreeLineBreaks(t *testing.T) {
	tests := map[string]struct {
		before string
		edit   contentChange
		want   string
	}{
		"lone CR starts a new line": {"ab\rcd", change(1, 1, 1, 2, "X"), "ab\rcX"},
		"CRLF is one break":         {"ab\r\ncd", change(1, 0, 1, 1, "X"), "ab\r\nXd"},
		"column stops before CR":    {"ab\rcd", change(0, 99, 0, 99, "!"), "ab!\rcd"},
		"column stops before CRLF":  {"ab\r\ncd", change(0, 99, 0, 99, "!"), "ab!\r\ncd"},
		"mixed breaks, third line":  {"a\rb\r\nc\nd", change(3, 0, 3, 1, "X"), "a\rb\r\nc\nX"},
		"delete across a lone CR":   {"one\rtwo\rthree", change(0, 1, 2, 2, ""), "oree"},
		"line past the end clamps":  {"ab\r", change(9, 0, 9, 0, "!"), "ab\r!"},
		"empty last line after CR":  {"ab\r", change(1, 0, 1, 0, "x"), "ab\rx"},
		"emoji before a lone CR":    {"a😀\rb", change(1, 0, 1, 0, "!"), "a😀\r!b"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			if got := applyChange(test.before, test.edit); got != test.want {
				t.Fatalf("applyChange(%q) = %q, want %q", test.before, got, test.want)
			}
		})
	}
}
