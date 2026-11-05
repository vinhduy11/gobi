package textlines

import (
	"reflect"
	"testing"
)

func TestFindBreak(t *testing.T) {
	tests := map[string]struct {
		text      string
		from      int
		wantAt    int
		wantLen   int
		wantFound bool
	}{
		"line feed":                 {"ab\ncd", 0, 2, 1, true},
		"carriage return line feed": {"ab\r\ncd", 0, 2, 2, true},
		"lone carriage return":      {"ab\rcd", 0, 2, 1, true},
		"carriage return at end":    {"ab\r", 0, 2, 1, true},
		"starts after the first":    {"a\nb\nc", 2, 3, 1, true},
		"none":                      {"abc", 0, -1, 0, false},
		"empty":                     {"", 0, -1, 0, false},
		"from past the end":         {"ab\n", 9, -1, 0, false},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			at, length := FindBreak(test.text, test.from)
			if (at >= 0) != test.wantFound || at != test.wantAt || length != test.wantLen {
				t.Fatalf("FindBreak(%q, %d) = (%d, %d), want (%d, %d)", test.text, test.from, at, length, test.wantAt, test.wantLen)
			}
		})
	}
}

func TestStartsHandlesAllThreeBreaks(t *testing.T) {
	starts, lengths := Starts("a\rb\r\nc\nd\r")
	if want := []int{0, 2, 5, 7, 9}; !reflect.DeepEqual(starts, want) {
		t.Fatalf("starts %v, want %v", starts, want)
	}
	if want := []int{0, 1, 2, 1, 1}; !reflect.DeepEqual(lengths, want) {
		t.Fatalf("break lengths %v, want %v", lengths, want)
	}
}

func TestLinesSplitsOnEveryBreakKind(t *testing.T) {
	if got, want := Lines("one\ntwo\r\nthree\rfour"), []string{"one", "two", "three", "four"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	if got := Lines("a\n"); !reflect.DeepEqual(got, []string{"a", ""}) {
		t.Fatalf("a trailing break leaves an empty last line, got %q", got)
	}
	if got := Lines(""); !reflect.DeepEqual(got, []string{""}) {
		t.Fatalf("empty text is one empty line, got %q", got)
	}
}
