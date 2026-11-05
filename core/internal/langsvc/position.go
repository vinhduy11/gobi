// Package langsvc is Gobi's built-in language service for the file types that have no official server
// worth installing: JSON (syntax errors, formatting, outline) and Markdown (outline, HTML preview).
// It speaks LSP over stdio so the broker can supervise it exactly like gopls.
package langsvc

import (
	"sort"
	"unicode/utf8"

	"gobi/core/internal/textlines"
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
	text         string
	lineStarts   []int
	breakLengths []int // length of the break just before each line; 0 for the first
}

func newLineIndex(text string) *lineIndex {
	starts, breakLengths := textlines.Starts(text)
	return &lineIndex{text: text, lineStarts: starts, breakLengths: breakLengths}
}

func (index *lineIndex) positionAt(offset int) position {
	offset = max(0, min(offset, len(index.text)))
	line := sort.Search(len(index.lineStarts), func(candidate int) bool { return index.lineStarts[candidate] > offset }) - 1
	// Between the CR and the LF of a "\r\n" the offset is still the end of the line before it.
	limit := min(offset, index.lineEnd(line))
	units := 0
	for scan := index.lineStarts[line]; scan < limit; {
		r, size := utf8.DecodeRuneInString(index.text[scan:limit])
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
	return index.lineStarts[line+1] - index.breakLengths[line+1]
}

func (index *lineIndex) lineCount() int {
	count := len(index.lineStarts)
	if index.lineStarts[count-1] == len(index.text) && count > 1 {
		count-- // a trailing newline does not start another line
	}
	return count
}
