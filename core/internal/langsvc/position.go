// Package langsvc is Gobi's built-in language service for the file types that have no official server
// worth installing: JSON (syntax errors, formatting, outline) and Markdown (outline, HTML preview).
// It speaks LSP over stdio so the broker can supervise it exactly like gopls.
package langsvc

import (
	"sort"
	"strings"
	"unicode/utf8"
)

type position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type lspRange struct {
	Start position `json:"start"`
	End   position `json:"end"`
}

// lineIndex converts byte offsets into LSP positions, whose columns count UTF-16 code units.
type lineIndex struct {
	text       string
	lineStarts []int
}

func newLineIndex(text string) *lineIndex {
	starts := []int{0}
	for offset := 0; offset < len(text); {
		newline := strings.IndexByte(text[offset:], '\n')
		if newline < 0 {
			break
		}
		offset += newline + 1
		starts = append(starts, offset)
	}
	return &lineIndex{text: text, lineStarts: starts}
}

func (index *lineIndex) positionAt(offset int) position {
	offset = max(0, min(offset, len(index.text)))
	line := sort.Search(len(index.lineStarts), func(candidate int) bool { return index.lineStarts[candidate] > offset }) - 1
	units := 0
	for scan := index.lineStarts[line]; scan < offset; {
		r, size := utf8.DecodeRuneInString(index.text[scan:offset])
		if r >= 0x10000 {
			units += 2
		} else {
			units++
		}
		scan += size
	}
	return position{Line: line, Character: units}
}

func (index *lineIndex) rangeOf(start, end int) lspRange {
	return lspRange{Start: index.positionAt(start), End: index.positionAt(end)}
}

// lineEnd returns the offset of the end of the given 0-based line, excluding its line break.
func (index *lineIndex) lineEnd(line int) int {
	if line+1 >= len(index.lineStarts) {
		return len(index.text)
	}
	end := index.lineStarts[line+1] - 1
	if end > index.lineStarts[line] && index.text[end-1] == '\r' {
		end--
	}
	return end
}

func (index *lineIndex) lineCount() int {
	count := len(index.lineStarts)
	if index.lineStarts[count-1] == len(index.text) && count > 1 {
		count-- // a trailing newline does not start another line
	}
	return count
}
