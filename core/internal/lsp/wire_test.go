package lsp

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestPeekHeader(t *testing.T) {
	tests := map[string]struct {
		payload    string
		wantID     string
		wantMethod string
		wantOK     bool
	}{
		"request":                 {`{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{}}`, "7", "textDocument/hover", true},
		"response":                {`{"jsonrpc":"2.0","id":"abc","result":null}`, `"abc"`, "", true},
		"notification":            {`{"jsonrpc":"2.0","method":"initialized","params":{}}`, "", "initialized", true},
		"whitespace everywhere":   {" {\n \"id\" :\t3 ,\r\n \"method\" : \"x\" } ", "3", "x", true},
		"id nested is ignored":    {`{"params":{"id":99,"method":"nope"},"id":1,"method":"real"}`, "1", "real", true},
		"id inside a string":      {`{"params":"{\"id\":99}","id":2,"method":"m"}`, "2", "m", true},
		"escaped key is decoded":  {`{"id":4,"method":"m"}`, "4", "m", true},
		"escaped method":          {`{"id":1,"method":"a\/b"}`, "1", "a/b", true},
		"array and object values": {`{"a":[1,{"id":5}],"id":6,"method":"m"}`, "6", "m", true},
		"empty object":            {`{}`, "", "", true},
		"not an object":           {`[1,2]`, "", "", false},
		"truncated":               {`{"id":1,"method":`, "", "", false},
		"missing colon":           {`{"id" 1}`, "", "", false},
		"duplicate id":            {`{"id":1,"id":2,"method":"m"}`, "", "", false},
		"duplicate method":        {`{"id":1,"method":"a","method":"b"}`, "", "", false},
		"empty input":             {``, "", "", false},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			id, method, ok := peekHeader([]byte(test.payload))
			if ok != test.wantOK || string(id) != test.wantID || method != test.wantMethod {
				t.Fatalf("peekHeader = (%q, %q, %v), want (%q, %q, %v)", id, method, ok, test.wantID, test.wantMethod, test.wantOK)
			}
		})
	}
}

// rewriteIDReference is the slow decode-and-encode version the fast path must agree with.
func rewriteIDReference(payload []byte, id json.RawMessage) ([]byte, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(payload, &fields); err != nil {
		return nil, err
	}
	fields["id"] = id
	return json.Marshal(fields)
}

func decodeAny(t *testing.T, payload []byte) any {
	t.Helper()
	var decoded any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("invalid JSON %q: %v", payload, err)
	}
	return decoded
}

func TestRewriteIDMatchesReference(t *testing.T) {
	payloads := []string{
		`{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{"id":"keep","position":{"line":1}}}`,
		`{"id":"gobi:3","jsonrpc":"2.0","result":{"applied":true}}`,
		`{"jsonrpc":"2.0","method":"m","params":{"text":"say \"id\":5 \\ done"},"id":10}`,
		" {\n \"id\" : 4 ,\n \"result\" : [1, 2, {\"id\": 9}] }\n",
		`{"id":null,"error":{"code":-1,"message":"x"}}`,
	}
	for _, payload := range payloads {
		fast, err := rewriteID([]byte(payload), json.RawMessage(`"new-id"`))
		if err != nil {
			t.Fatalf("%s: %v", payload, err)
		}
		want, err := rewriteIDReference([]byte(payload), json.RawMessage(`"new-id"`))
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(decodeAny(t, fast), decodeAny(t, want)) {
			t.Fatalf("payload %s\n fast: %s\n want: %s", payload, fast, want)
		}
	}
}

func TestRewriteIDLeavesTheRestOfThePayloadByteForByte(t *testing.T) {
	payload := `{"jsonrpc":"2.0",  "id": 5 ,"result":{"big":[1,2,3]}}`
	got, err := rewriteID([]byte(payload), json.RawMessage("42"))
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"jsonrpc":"2.0",  "id": 42 ,"result":{"big":[1,2,3]}}`; string(got) != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestRewriteIDRejectsPayloadsItCannotTranslateSafely(t *testing.T) {
	for name, payload := range map[string]string{
		"no id":        `{"method":"m"}`,
		"duplicate id": `{"id":1,"id":2}`,
		"not object":   `[1]`,
		"truncated":    `{"id":1,`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := rewriteID([]byte(payload), json.RawMessage("1")); err == nil {
				t.Fatal("want an error")
			}
		})
	}
}

func FuzzRewriteID(f *testing.F) {
	f.Add([]byte(`{"id":1,"method":"m","params":{"id":2}}`))
	f.Add([]byte(`{"a":"\"id\":","id":"x"}`))
	f.Add([]byte(`{"id":`))
	f.Fuzz(func(t *testing.T, payload []byte) {
		peekHeader(payload)
		fast, err := rewriteID(payload, json.RawMessage("7"))
		if err != nil || !json.Valid(payload) {
			return
		}
		want, refErr := rewriteIDReference(payload, json.RawMessage("7"))
		if refErr != nil {
			return
		}
		var fastDecoded, wantDecoded any
		if json.Unmarshal(fast, &fastDecoded) != nil {
			t.Fatalf("fast path produced invalid JSON from %q: %q", payload, fast)
		}
		json.Unmarshal(want, &wantDecoded)
		if !reflect.DeepEqual(fastDecoded, wantDecoded) {
			t.Fatalf("payload %q\n fast: %s\n want: %s", payload, fast, want)
		}
	})
}
