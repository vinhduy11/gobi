package langsvc

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// LSP SymbolKind values used for JSON and Markdown outlines.
const (
	symbolKindNamespace = 3
	symbolKindString    = 15
	symbolKindNumber    = 16
	symbolKindBoolean   = 17
	symbolKindArray     = 18
	symbolKindObject    = 19
	symbolKindNull      = 21
)

const (
	maxJSONDepth    = 200
	maxArraySymbols = 500
	maxDetailBytes  = 60
)

type syntaxError struct {
	Offset  int
	Message string
}

// jsonSymbol is an outline entry: a member of an object or an element of an array. Offsets are bytes.
// Start and End cover the value; KeyStart and KeyEnd cover the key (for array elements, the value).
type jsonSymbol struct {
	Name             string
	Kind             int
	Detail           string
	Start, End       int
	KeyStart, KeyEnd int
	Children         []jsonSymbol
}

type parsedValue struct {
	end      int
	kind     int
	children []jsonSymbol
}

// parseJSON validates strict JSON and builds the outline of the root object or array. It reports only
// the first error. It accepts exactly what encoding/json accepts (checked by a fuzz test), apart from
// nesting beyond maxJSONDepth.
func parseJSON(text string) ([]jsonSymbol, *syntaxError) {
	scanner := jsonParser{text: text}
	root, problem := scanner.parseValue(scanner.space(0), 0)
	if problem != nil {
		return nil, problem
	}
	if rest := scanner.space(root.end); rest < len(text) {
		return nil, scanner.unexpected(rest, "after the value")
	}
	return root.children, nil
}

type jsonParser struct{ text string }

func (scanner *jsonParser) space(at int) int {
	for at < len(scanner.text) && (scanner.text[at] == ' ' || scanner.text[at] == '\t' || scanner.text[at] == '\n' || scanner.text[at] == '\r') {
		at++
	}
	return at
}

func (scanner *jsonParser) unexpected(at int, context string) *syntaxError {
	r, _ := utf8.DecodeRuneInString(scanner.text[at:])
	return &syntaxError{at, fmt.Sprintf("unexpected character %q %s", r, context)}
}

func (scanner *jsonParser) endOfInput() *syntaxError {
	return &syntaxError{len(scanner.text), "unexpected end of input"}
}

func (scanner *jsonParser) parseValue(at, depth int) (parsedValue, *syntaxError) {
	if at >= len(scanner.text) {
		return parsedValue{}, scanner.endOfInput()
	}
	switch character := scanner.text[at]; {
	case character == '{':
		return scanner.parseObject(at, depth)
	case character == '[':
		return scanner.parseArray(at, depth)
	case character == '"':
		end, problem := scanner.stringEnd(at)
		return parsedValue{end: end, kind: symbolKindString}, problem
	case character == '-' || isDigit(character):
		end, problem := scanner.number(at)
		return parsedValue{end: end, kind: symbolKindNumber}, problem
	default:
		for literal, kind := range map[string]int{"true": symbolKindBoolean, "false": symbolKindBoolean, "null": symbolKindNull} {
			if strings.HasPrefix(scanner.text[at:], literal) {
				return parsedValue{end: at + len(literal), kind: kind}, nil
			}
		}
		if character == 't' || character == 'f' || character == 'n' {
			return parsedValue{}, &syntaxError{at, "invalid literal, expected true, false or null"}
		}
		return parsedValue{}, scanner.unexpected(at, ", expected a value")
	}
}

func (scanner *jsonParser) parseObject(at, depth int) (parsedValue, *syntaxError) {
	if depth >= maxJSONDepth {
		return parsedValue{}, &syntaxError{at, "nesting too deep"}
	}
	var members []jsonSymbol
	pos := scanner.space(at + 1)
	if pos < len(scanner.text) && scanner.text[pos] == '}' {
		return parsedValue{end: pos + 1, kind: symbolKindObject}, nil
	}
	for first := true; ; first = false {
		if pos >= len(scanner.text) {
			return parsedValue{}, scanner.endOfInput()
		}
		if scanner.text[pos] != '"' {
			if first {
				return parsedValue{}, &syntaxError{pos, "expected a string key or '}'"}
			}
			return parsedValue{}, &syntaxError{pos, "expected a string key; trailing commas are not allowed"}
		}
		keyEnd, problem := scanner.stringEnd(pos)
		if problem != nil {
			return parsedValue{}, problem
		}
		keyStart := pos
		pos = scanner.space(keyEnd)
		if pos >= len(scanner.text) {
			return parsedValue{}, scanner.endOfInput()
		}
		if scanner.text[pos] != ':' {
			return parsedValue{}, &syntaxError{pos, "expected ':' after the key"}
		}
		valueStart := scanner.space(pos + 1)
		member, problem := scanner.parseValue(valueStart, depth+1)
		if problem != nil {
			return parsedValue{}, problem
		}
		members = append(members, jsonSymbol{
			Name: decodeJSONKey(scanner.text[keyStart:keyEnd]), Kind: member.kind, Detail: scanner.detail(valueStart, member),
			Start: valueStart, End: member.end, KeyStart: keyStart, KeyEnd: keyEnd, Children: member.children,
		})
		pos = scanner.space(member.end)
		if pos >= len(scanner.text) {
			return parsedValue{}, scanner.endOfInput()
		}
		switch scanner.text[pos] {
		case ',':
			pos = scanner.space(pos + 1)
		case '}':
			return parsedValue{end: pos + 1, kind: symbolKindObject, children: members}, nil
		default:
			return parsedValue{}, &syntaxError{pos, "expected ',' or '}'"}
		}
	}
}

func (scanner *jsonParser) parseArray(at, depth int) (parsedValue, *syntaxError) {
	if depth >= maxJSONDepth {
		return parsedValue{}, &syntaxError{at, "nesting too deep"}
	}
	var elements []jsonSymbol
	pos := scanner.space(at + 1)
	if pos < len(scanner.text) && scanner.text[pos] == ']' {
		return parsedValue{end: pos + 1, kind: symbolKindArray}, nil
	}
	for index := 0; ; index++ {
		element, problem := scanner.parseValue(pos, depth+1)
		if problem != nil {
			return parsedValue{}, problem
		}
		if index < maxArraySymbols {
			elements = append(elements, jsonSymbol{
				Name: fmt.Sprint(index), Kind: element.kind, Detail: scanner.detail(pos, element),
				Start: pos, End: element.end, KeyStart: pos, KeyEnd: element.end, Children: element.children,
			})
		}
		pos = scanner.space(element.end)
		if pos >= len(scanner.text) {
			return parsedValue{}, scanner.endOfInput()
		}
		switch scanner.text[pos] {
		case ',':
			pos = scanner.space(pos + 1)
		case ']':
			return parsedValue{end: pos + 1, kind: symbolKindArray, children: elements}, nil
		default:
			return parsedValue{}, &syntaxError{pos, "expected ',' or ']'"}
		}
	}
}

// detail shows the raw text of scalar values, shortened.
func (scanner *jsonParser) detail(start int, parsed parsedValue) string {
	if parsed.kind == symbolKindObject || parsed.kind == symbolKindArray {
		return ""
	}
	raw := scanner.text[start:parsed.end]
	if len(raw) > maxDetailBytes {
		raw = strings.ToValidUTF8(raw[:maxDetailBytes], "") + "…"
	}
	return raw
}

// stringEnd returns the offset just past the string starting at at.
func (scanner *jsonParser) stringEnd(at int) (int, *syntaxError) {
	for pos := at + 1; pos < len(scanner.text); pos++ {
		switch character := scanner.text[pos]; {
		case character == '"':
			return pos + 1, nil
		case character < 0x20:
			return 0, &syntaxError{pos, "control character in string"}
		case character == '\\':
			pos++
			if pos >= len(scanner.text) {
				return 0, scanner.endOfInput()
			}
			switch scanner.text[pos] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
			case 'u':
				for digit := 1; digit <= 4; digit++ {
					if pos+digit >= len(scanner.text) {
						return 0, scanner.endOfInput()
					}
					if !isHexDigit(scanner.text[pos+digit]) {
						return 0, &syntaxError{pos + digit, "invalid unicode escape"}
					}
				}
				pos += 4
			default:
				return 0, &syntaxError{pos, "invalid escape sequence"}
			}
		}
	}
	return 0, scanner.endOfInput()
}

func (scanner *jsonParser) number(at int) (int, *syntaxError) {
	pos := at
	if scanner.text[pos] == '-' {
		pos++
	}
	if pos >= len(scanner.text) || !isDigit(scanner.text[pos]) {
		return 0, &syntaxError{pos, "expected a digit"}
	}
	if scanner.text[pos] == '0' {
		pos++
	} else {
		pos = scanner.digits(pos)
	}
	if pos < len(scanner.text) && scanner.text[pos] == '.' {
		pos++
		if pos >= len(scanner.text) || !isDigit(scanner.text[pos]) {
			return 0, &syntaxError{pos, "expected a digit"}
		}
		pos = scanner.digits(pos)
	}
	if pos < len(scanner.text) && (scanner.text[pos] == 'e' || scanner.text[pos] == 'E') {
		pos++
		if pos < len(scanner.text) && (scanner.text[pos] == '+' || scanner.text[pos] == '-') {
			pos++
		}
		if pos >= len(scanner.text) || !isDigit(scanner.text[pos]) {
			return 0, &syntaxError{pos, "expected a digit"}
		}
		pos = scanner.digits(pos)
	}
	return pos, nil
}

func (scanner *jsonParser) digits(at int) int {
	for at < len(scanner.text) && isDigit(scanner.text[at]) {
		at++
	}
	return at
}

func isDigit(character byte) bool { return character >= '0' && character <= '9' }

func isHexDigit(character byte) bool {
	return isDigit(character) || (character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F')
}

func decodeJSONKey(quoted string) string {
	var key string
	if json.Unmarshal([]byte(quoted), &key) != nil {
		return quoted
	}
	return key
}
