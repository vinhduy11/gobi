package generate

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// Edit replaces the range [start, end) of the original text with Text. Lines are 0-based and characters are UTF-16
// code units, as in LSP, so the UI can apply the whole set in one undo group.
type Edit struct {
	StartLine, StartChar int
	EndLine, EndChar     int
	Text                 string
}

// byteEdit is an edit in byte offsets of the original text.
type byteEdit struct {
	start, end int
	text       string
}

func position(source string, offset int) (line, char int) {
	line = strings.Count(source[:offset], "\n")
	lineStart := strings.LastIndex(source[:offset], "\n") + 1
	return line, len(utf16.Encode([]rune(source[lineStart:offset])))
}

func offsetOf(source string, line, char int) (int, error) {
	start := 0
	for ; line > 0; line-- {
		next := strings.IndexByte(source[start:], '\n')
		if next < 0 {
			return 0, errors.New("edit line is past the end of the text")
		}
		start += next + 1
	}
	offset, units := start, 0
	for units < char {
		if offset >= len(source) || source[offset] == '\n' {
			return 0, errors.New("edit character is past the end of the line")
		}
		r, size := utf8.DecodeRuneInString(source[offset:])
		units += utf16.RuneLen(r)
		offset += size
	}
	return offset, nil
}

func toEdits(source string, edits []byteEdit) []Edit {
	sort.SliceStable(edits, func(i, j int) bool { return edits[i].start < edits[j].start })
	out := make([]Edit, 0, len(edits))
	for _, e := range edits {
		sl, sc := position(source, e.start)
		el, ec := position(source, e.end)
		out = append(out, Edit{sl, sc, el, ec, e.text})
	}
	return out
}

// ApplyEdits applies edits, whose ranges refer to the original text and must not overlap, and returns the new text.
func ApplyEdits(source string, edits []Edit) (string, error) {
	type span struct {
		start, end int
		text       string
	}
	spans := make([]span, 0, len(edits))
	for _, e := range edits {
		start, err := offsetOf(source, e.StartLine, e.StartChar)
		if err != nil {
			return "", err
		}
		end, err := offsetOf(source, e.EndLine, e.EndChar)
		if err != nil {
			return "", err
		}
		spans = append(spans, span{start, end, e.Text})
	}
	sort.SliceStable(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
	var b strings.Builder
	last := 0
	for _, s := range spans {
		if s.start < last || s.end < s.start {
			return "", fmt.Errorf("edits overlap near offset %d", s.start)
		}
		b.WriteString(source[last:s.start])
		b.WriteString(s.text)
		last = s.end
	}
	b.WriteString(source[last:])
	return b.String(), nil
}
