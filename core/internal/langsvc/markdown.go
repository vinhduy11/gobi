package langsvc

import (
	"bytes"
	"strings"

	"gobi/core/internal/textlines"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
)

type heading struct {
	Level int
	Text  string
	Line  int // 0-based
}

// mdSymbol is a Markdown outline entry spanning its whole section.
type mdSymbol struct {
	Name               string
	StartLine, EndLine int
	Children           []mdSymbol
}

// headings lists ATX and setext headings outside fenced code blocks.
// ponytail: a setext heading takes only the line directly above its underline, not a multi-line paragraph.
func headings(text string) []heading {
	lines := textlines.Lines(text)

	var found []heading
	var fenceChar byte
	fenceLength := 0
	for index := 0; index < len(lines); index++ {
		line := lines[index]
		stripped, indented := stripIndent(line)
		if fenceChar != 0 {
			if closesFence(stripped, indented, fenceChar, fenceLength) {
				fenceChar, fenceLength = 0, 0
			}
			continue
		}
		if char, length := opensFence(stripped, indented); length > 0 {
			fenceChar, fenceLength = char, length
			continue
		}
		if indented {
			continue
		}
		if level, content, ok := atxHeading(stripped); ok {
			if content != "" {
				found = append(found, heading{level, content, index})
			}
			continue
		}
		if index+1 < len(lines) && isSetextCandidate(stripped) {
			if level := setextLevel(lines[index+1]); level > 0 {
				found = append(found, heading{level, strings.TrimSpace(stripped), index})
				index++
			}
		}
	}
	return found
}

// stripIndent removes up to three leading spaces; indented reports four or more (an indented code block).
func stripIndent(line string) (stripped string, indented bool) {
	spaces := 0
	for spaces < len(line) && line[spaces] == ' ' {
		spaces++
	}
	if spaces >= 4 || (spaces < len(line) && line[spaces] == '\t' && spaces == 0) {
		return line, true
	}
	return line[spaces:], false
}

func opensFence(stripped string, indented bool) (byte, int) {
	if indented || len(stripped) < 3 || (stripped[0] != '`' && stripped[0] != '~') {
		return 0, 0
	}
	length := 0
	for length < len(stripped) && stripped[length] == stripped[0] {
		length++
	}
	if length < 3 || (stripped[0] == '`' && strings.Contains(stripped[length:], "`")) {
		return 0, 0
	}
	return stripped[0], length
}

func closesFence(stripped string, indented bool, char byte, minLength int) bool {
	if indented || len(stripped) < minLength {
		return false
	}
	length := 0
	for length < len(stripped) && stripped[length] == char {
		length++
	}
	return length >= minLength && strings.TrimSpace(stripped[length:]) == ""
}

func atxHeading(stripped string) (level int, content string, ok bool) {
	for level < len(stripped) && stripped[level] == '#' {
		level++
	}
	if level == 0 || level > 6 || (level < len(stripped) && stripped[level] != ' ' && stripped[level] != '\t') {
		return 0, "", false
	}
	content = strings.TrimSpace(stripped[level:])
	if closing := strings.TrimRight(content, "#"); closing == "" {
		content = ""
	} else if len(closing) < len(content) && (closing[len(closing)-1] == ' ' || closing[len(closing)-1] == '\t') {
		content = strings.TrimSpace(closing)
	}
	return level, content, true
}

func isSetextCandidate(stripped string) bool {
	trimmed := strings.TrimSpace(stripped)
	if trimmed == "" || setextLevel(stripped) > 0 {
		return false
	}
	for _, blockStart := range []string{">", "- ", "* ", "+ ", "#"} {
		if strings.HasPrefix(trimmed, blockStart) {
			return false
		}
	}
	return true
}

// setextLevel returns 1 for a "===" underline, 2 for "---", and 0 otherwise.
func setextLevel(line string) int {
	stripped, indented := stripIndent(line)
	trimmed := strings.TrimRight(stripped, " \t")
	if indented || trimmed == "" {
		return 0
	}
	switch {
	case strings.Trim(trimmed, "=") == "":
		return 1
	case strings.Trim(trimmed, "-") == "":
		return 2
	}
	return 0
}

// markdownSymbols nests headings by level; a section ends before the next heading of the same or a higher level.
func markdownSymbols(text string) []mdSymbol {
	found := headings(text)
	lastLine := newLineIndex(text).lineCount() - 1

	type frame struct {
		level  int
		symbol *mdSymbol
	}
	var roots []mdSymbol
	var stack []frame
	for index, current := range found {
		for len(stack) > 0 && stack[len(stack)-1].level >= current.Level {
			stack = stack[:len(stack)-1]
		}
		endLine := lastLine
		for _, later := range found[index+1:] {
			if later.Level <= current.Level {
				endLine = later.Line - 1
				break
			}
		}
		symbol := mdSymbol{Name: current.Text, StartLine: current.Line, EndLine: endLine}
		target := &roots
		if len(stack) > 0 {
			target = &stack[len(stack)-1].symbol.Children
		}
		*target = append(*target, symbol)
		stack = append(stack, frame{level: current.Level, symbol: &(*target)[len(*target)-1]})
	}
	return roots
}

var markdownRenderer = goldmark.New(
	goldmark.WithExtensions(extension.GFM),
	goldmark.WithParserOptions(parser.WithAutoHeadingID()),
	// Raw HTML and dangerous URL schemes (javascript:, data:, ...) are dropped by goldmark's defaults.
)

func renderMarkdown(text string) string {
	var rendered bytes.Buffer
	if err := markdownRenderer.Convert([]byte(text), &rendered); err != nil {
		return ""
	}
	return rendered.String()
}
