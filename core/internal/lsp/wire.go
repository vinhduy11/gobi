package lsp

import (
	"encoding/json"
	"errors"
)

// The broker forwards most messages untouched. These helpers read the top-level "id" and "method"
// and swap the id by splicing bytes, so a message costs one scan instead of a decode and re-encode
// (the decode/encode version ran at about 100 MB/s on large completion lists).
//
// A message with a duplicate "id" or "method" is refused: parsers disagree about which duplicate
// wins, and a client could use that to dodge id translation.

var errCannotTranslate = errors.New("lsp: message has no single top-level id")

// peekHeader returns the raw top-level id (nil when absent) and the method (empty when absent).
// ok is false when the payload is not a JSON object the scanner can follow or has duplicate id/method.
func peekHeader(payload []byte) (id json.RawMessage, method string, ok bool) {
	seenID, seenMethod := false, false
	complete := scanObject(payload, func(key string, start, end int) bool {
		switch key {
		case "id":
			if seenID {
				return false
			}
			seenID = true
			id = json.RawMessage(payload[start:end])
		case "method":
			if seenMethod {
				return false
			}
			seenMethod = true
			if json.Unmarshal(payload[start:end], &method) != nil {
				return false
			}
		}
		return true
	})
	if !complete {
		return nil, "", false
	}
	return id, method, true
}

// rewriteID returns payload with its top-level id replaced by newID.
func rewriteID(payload []byte, newID json.RawMessage) ([]byte, error) {
	idStart, idEnd, count := -1, -1, 0
	complete := scanObject(payload, func(key string, start, end int) bool {
		if key == "id" {
			idStart, idEnd = start, end
			count++
		}
		return true
	})
	if !complete || count != 1 {
		return nil, errCannotTranslate
	}
	rewritten := make([]byte, 0, len(payload)-(idEnd-idStart)+len(newID))
	rewritten = append(rewritten, payload[:idStart]...)
	rewritten = append(rewritten, newID...)
	rewritten = append(rewritten, payload[idEnd:]...)
	return rewritten, nil
}

// scanObject walks the members of the JSON object in payload without decoding values, calling visit
// with each decoded key and the byte range of its value. It stops early, reporting failure, when
// visit returns false. It reports false for anything that is not a well-formed-enough object.
func scanObject(payload []byte, visit func(key string, start, end int) bool) bool {
	at := skipSpace(payload, 0)
	if at >= len(payload) || payload[at] != '{' {
		return false
	}
	at = skipSpace(payload, at+1)
	if at < len(payload) && payload[at] == '}' {
		return true
	}
	for {
		if at >= len(payload) || payload[at] != '"' {
			return false
		}
		keyEnd := skipString(payload, at)
		if keyEnd < 0 {
			return false
		}
		key, ok := decodeKey(payload[at:keyEnd])
		if !ok {
			return false
		}
		at = skipSpace(payload, keyEnd)
		if at >= len(payload) || payload[at] != ':' {
			return false
		}
		at = skipSpace(payload, at+1)
		valueEnd := skipValue(payload, at)
		if valueEnd < 0 {
			return false
		}
		if !visit(key, at, valueEnd) {
			return false
		}
		at = skipSpace(payload, valueEnd)
		if at >= len(payload) {
			return false
		}
		switch payload[at] {
		case ',':
			at = skipSpace(payload, at+1)
		case '}':
			return true
		default:
			return false
		}
	}
}

func decodeKey(quoted []byte) (string, bool) {
	for _, char := range quoted {
		if char == '\\' {
			var key string
			return key, json.Unmarshal(quoted, &key) == nil
		}
	}
	return string(quoted[1 : len(quoted)-1]), true
}

func skipSpace(payload []byte, at int) int {
	for at < len(payload) && (payload[at] == ' ' || payload[at] == '\t' || payload[at] == '\n' || payload[at] == '\r') {
		at++
	}
	return at
}

// skipString returns the index just past the string that starts at payload[at], or -1.
func skipString(payload []byte, at int) int {
	for scan := at + 1; scan < len(payload); scan++ {
		switch payload[scan] {
		case '\\':
			scan++
		case '"':
			return scan + 1
		}
	}
	return -1
}

// skipValue returns the index just past the JSON value that starts at payload[at], or -1.
func skipValue(payload []byte, at int) int {
	if at >= len(payload) {
		return -1
	}
	switch payload[at] {
	case '"':
		return skipString(payload, at)
	case '{', '[':
		depth := 0
		for scan := at; scan < len(payload); scan++ {
			switch payload[scan] {
			case '"':
				end := skipString(payload, scan)
				if end < 0 {
					return -1
				}
				scan = end - 1
			case '{', '[':
				depth++
			case '}', ']':
				depth--
				if depth == 0 {
					return scan + 1
				}
			}
		}
		return -1
	}
	scan := at
	for scan < len(payload) && !isValueEnd(payload[scan]) {
		scan++
	}
	if scan == at {
		return -1
	}
	return scan
}

func isValueEnd(char byte) bool {
	switch char {
	case ',', '}', ']', ' ', '\t', '\n', '\r':
		return true
	}
	return false
}
