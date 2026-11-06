package generate

import (
	"go/token"
	"strings"
	"unicode"
)

// initialisms are written in capitals inside an exported name (UserID, not UserId), as Go Code Review Comments ask.
var initialisms = map[string]bool{
	"id": true, "url": true, "uri": true, "http": true, "https": true, "api": true, "ip": true, "json": true,
	"xml": true, "sql": true, "uuid": true, "tcp": true, "udp": true, "html": true, "cpu": true, "ttl": true,
	"tls": true, "ssh": true, "dns": true,
}

// words splits a camelCase or snake_case identifier into its words: "userID" gives user, ID.
func words(name string) []string {
	runes := []rune(strings.TrimLeft(name, "_"))
	var out []string
	start := 0
	for i := 1; i < len(runes); i++ {
		switch {
		case runes[i] == '_':
			out = append(out, string(runes[start:i]))
			start = i + 1
		case unicode.IsUpper(runes[i]) && i > start && (unicode.IsLower(runes[i-1]) ||
			(i+1 < len(runes) && unicode.IsLower(runes[i+1]) && unicode.IsUpper(runes[i-1]))):
			out = append(out, string(runes[start:i]))
			start = i
		}
	}
	if start < len(runes) {
		out = append(out, string(runes[start:]))
	}
	var kept []string
	for _, word := range out {
		if word != "" {
			kept = append(kept, word)
		}
	}
	return kept
}

// exported turns a field or type name into its exported MixedCaps form: addr to Addr, userID to UserID.
func exported(name string) string {
	var b strings.Builder
	for _, word := range words(name) {
		if initialisms[strings.ToLower(word)] {
			b.WriteString(strings.ToUpper(word))
			continue
		}
		runes := []rune(word)
		runes[0] = unicode.ToUpper(runes[0])
		b.WriteString(string(runes))
	}
	return b.String()
}

// local turns a name into a parameter or variable name: Addr to addr, URL to url, HTTPServer to httpServer.
func local(name string) string {
	runes := []rune(strings.TrimLeft(name, "_"))
	upper := 0
	for upper < len(runes) && unicode.IsUpper(runes[upper]) {
		upper++
	}
	lower := upper
	if upper > 1 && upper < len(runes) {
		lower = upper - 1
	}
	if lower == 0 {
		lower = 1
	}
	for i := 0; i < lower && i < len(runes); i++ {
		runes[i] = unicode.ToLower(runes[i])
	}
	out := string(runes)
	if token.IsKeyword(out) {
		return out + "Value"
	}
	return out
}

// receiverName is the short receiver name Effective Go asks for: the first letter of the type, in lower case.
func receiverName(typeName string) string {
	for _, r := range typeName {
		return string(unicode.ToLower(r))
	}
	return "r"
}

func isUnexported(name string) bool {
	for _, r := range name {
		return !unicode.IsUpper(r)
	}
	return false
}

// verb is the fmt verb for a field in String(): %s for strings and named string types, %d for integers, %t for bool and
// %v for everything else. A named integer type is left to %v so that its own String method, if any, still runs.
func verb(f Field) string {
	t := f.Type
	if f.Underlying == "string" {
		t = "string"
	} else if f.Underlying != "" && f.Underlying != f.Type {
		return "%v"
	}
	switch t {
	case "string":
		return "%s"
	case "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr":
		return "%d"
	case "bool":
		return "%t"
	}
	return "%v"
}
