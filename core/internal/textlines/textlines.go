// Package textlines finds line breaks the way the Language Server Protocol defines them: "\n", "\r\n" (one break) and a
// lone "\r". Positions the broker and the built-in language service compute must agree with the editor and with gopls,
// so they all use this one definition.
package textlines

import "strings"

// FindBreak returns the offset of the first line break at or after from and its length (1 or 2), or (-1, 0).
func FindBreak(text string, from int) (at, length int) {
	if from < 0 || from >= len(text) {
		return -1, 0
	}
	found := strings.IndexAny(text[from:], "\r\n")
	if found < 0 {
		return -1, 0
	}
	at = from + found
	if text[at] == '\r' && at+1 < len(text) && text[at+1] == '\n' {
		return at, 2
	}
	return at, 1
}

// Starts returns the offset where each line starts (the first is 0) and the length of the break just before each line
// (0 for the first). A text that ends with a break has an empty last line.
func Starts(text string) (starts, breakLengths []int) {
	starts, breakLengths = []int{0}, []int{0}
	for from := 0; ; {
		at, length := FindBreak(text, from)
		if at < 0 {
			return starts, breakLengths
		}
		from = at + length
		starts = append(starts, from)
		breakLengths = append(breakLengths, length)
	}
}

// Lines splits text into lines without their breaks.
func Lines(text string) []string {
	starts, breakLengths := Starts(text)
	lines := make([]string, len(starts))
	for index, start := range starts {
		end := len(text)
		if index+1 < len(starts) {
			end = starts[index+1] - breakLengths[index+1]
		}
		lines[index] = text[start:end]
	}
	return lines
}
