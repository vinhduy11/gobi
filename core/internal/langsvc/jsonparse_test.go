package langsvc

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseJSONAcceptsValidDocuments(t *testing.T) {
	for _, document := range []string{
		`{}`, `[]`, `"text"`, `42`, `-0.5e+3`, `true`, `null`,
		` { "a" : 1 , "b" : [ true , null , "x" ] , "c" : { "d" : -1.5e3 } } `,
		`"é\n\"\\"`,
		"{\n\t\"a\": [1, 2, 3]\n}\n",
	} {
		if _, problem := parseJSON(document); problem != nil {
			t.Errorf("%q rejected: %+v", document, problem)
		}
	}
}

func TestParseJSONReportsFirstErrorAtTheRightOffset(t *testing.T) {
	tests := map[string]struct {
		document string
		offset   int
		message  string
	}{
		"trailing comma":        {`{"a":1,}`, 7, "expected"},
		"missing colon":         {`{"a" 1}`, 5, "':'"},
		"missing value":         {`{"a":}`, 5, "value"},
		"unterminated array":    {`[1,2`, 4, "end of input"},
		"single quotes":         {`{'a':1}`, 1, "expected"},
		"leading zero":          {`01`, 1, "after"},
		"missing comma":         {`[1 2]`, 3, "','"},
		"unterminated string":   {`"abc`, 4, "end of input"},
		"bad escape":            {`"a\qb"`, 3, "escape"},
		"raw newline in string": {"\"a\nb\"", 2, "control"},
		"bad literal":           {`tru`, 0, "literal"},
		"text after value":      {`{"a":1} x`, 8, "after"},
		"lone minus":            {`-`, 1, "digit"},
		"fraction needs digit":  {`1.`, 2, "digit"},
		"short unicode escape":  {`"\u12"`, 5, "escape"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			_, problem := parseJSON(test.document)
			if problem == nil {
				t.Fatal("want an error")
			}
			if problem.Offset != test.offset || !strings.Contains(problem.Message, test.message) {
				t.Fatalf("got offset %d %q, want offset %d containing %q", problem.Offset, problem.Message, test.offset, test.message)
			}
		})
	}
}

func TestParseJSONRefusesAbsurdNesting(t *testing.T) {
	_, problem := parseJSON(strings.Repeat("[", 500))
	if problem == nil || !strings.Contains(problem.Message, "too deep") {
		t.Fatalf("got %+v", problem)
	}
}

func TestParseJSONBuildsSymbolTreeWithRanges(t *testing.T) {
	document := `{"a": {"b": [1, 2]}, "c": "x"}`
	symbols, problem := parseJSON(document)
	if problem != nil {
		t.Fatal(problem)
	}
	if len(symbols) != 2 || symbols[0].Name != "a" || symbols[1].Name != "c" {
		t.Fatalf("top level: %+v", symbols)
	}
	member := symbols[0]
	if member.Kind != symbolKindObject || len(member.Children) != 1 || member.Children[0].Name != "b" {
		t.Fatalf("a: %+v", member)
	}
	array := member.Children[0]
	if array.Kind != symbolKindArray || len(array.Children) != 2 || array.Children[0].Name != "0" || array.Children[1].Name != "1" {
		t.Fatalf("b: %+v", array)
	}
	if got := document[member.Start:member.End]; got != `{"b": [1, 2]}` {
		t.Fatalf("a value range covers %q", got)
	}
	if got := document[member.KeyStart:member.KeyEnd]; got != `"a"` {
		t.Fatalf("a key range covers %q", got)
	}
	if symbols[1].Kind != symbolKindString || symbols[1].Detail != `"x"` {
		t.Fatalf("c: %+v", symbols[1])
	}
}

func TestParseJSONSymbolsForArrayRootAndScalars(t *testing.T) {
	symbols, problem := parseJSON(`[{"id": 1}, true]`)
	if problem != nil || len(symbols) != 2 || symbols[0].Name != "0" || symbols[0].Children[0].Name != "id" || symbols[1].Kind != symbolKindBoolean {
		t.Fatalf("got %+v, %v", symbols, problem)
	}
	if symbols, problem := parseJSON(`42`); problem != nil || len(symbols) != 0 {
		t.Fatalf("scalar root has no symbols, got %+v, %v", symbols, problem)
	}
}

func TestParseJSONCapsHugeArrays(t *testing.T) {
	symbols, problem := parseJSON("[" + strings.Repeat("1,", maxArraySymbols+50) + "1]")
	if problem != nil || len(symbols) != maxArraySymbols {
		t.Fatalf("want %d capped symbols, got %d, %v", maxArraySymbols, len(symbols), problem)
	}
}

// The hand-written parser must accept exactly what encoding/json accepts.
func FuzzParseJSONAgreesWithStdlib(f *testing.F) {
	f.Add(`{"a":[1,2,{"b":null}]}`)
	f.Add(`[1,]`)
	f.Add(`"\ud800"`)
	f.Add(`{"a":01}`)
	f.Fuzz(func(t *testing.T, document string) {
		_, problem := parseJSON(document)
		if problem != nil && strings.Contains(problem.Message, "too deep") {
			return
		}
		if (problem == nil) != json.Valid([]byte(document)) {
			t.Fatalf("%q: parser says error=%v, encoding/json says valid=%v", document, problem, json.Valid([]byte(document)))
		}
		if problem != nil && (problem.Offset < 0 || problem.Offset > len(document)) {
			t.Fatalf("%q: offset %d out of range", document, problem.Offset)
		}
	})
}
