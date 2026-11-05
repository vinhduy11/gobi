package lsp

import (
	"encoding/json"
	"strings"
	"testing"
)

// completionPayload builds a response shaped like a gopls completion list with the given item count.
func completionPayload(items int) []byte {
	entries := make([]map[string]any, items)
	for index := range entries {
		entries[index] = map[string]any{
			"label":  "SomeExportedIdentifier",
			"kind":   3,
			"detail": "func(ctx context.Context, name string) (*Result, error)",
			"documentation": map[string]any{
				"kind":  "markdown",
				"value": strings.Repeat("documentation text ", 8),
			},
			"textEdit": map[string]any{"newText": "SomeExportedIdentifier", "range": map[string]any{"start": map[string]int{"line": 10, "character": 4}, "end": map[string]int{"line": 10, "character": 8}}},
		}
	}
	result, _ := json.Marshal(map[string]any{"isIncomplete": false, "items": entries})
	payload, _ := json.Marshal(message{JSONRPC: "2.0", ID: json.RawMessage("42"), Result: result})
	return payload
}

// BenchmarkRewriteID is the per-message cost the broker adds when it translates a request id.
func BenchmarkRewriteID(b *testing.B) {
	for name, items := range map[string]int{"small_20_items": 20, "large_2000_items": 2000} {
		payload := completionPayload(items)
		b.Run(name, func(b *testing.B) {
			b.SetBytes(int64(len(payload)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := rewriteID(payload, json.RawMessage("7")); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkPeekHeader is the cost of reading only id and method, which every forwarded message pays.
// full_decode is what the broker did before it scanned for the header.
func BenchmarkPeekHeader(b *testing.B) {
	payload := completionPayload(2000)
	b.Run("scan", func(b *testing.B) {
		b.SetBytes(int64(len(payload)))
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			if _, _, ok := peekHeader(payload); !ok {
				b.Fatal("peek failed")
			}
		}
	})
	b.Run("full_decode", func(b *testing.B) {
		b.SetBytes(int64(len(payload)))
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			var incoming message
			if err := json.Unmarshal(payload, &incoming); err != nil {
				b.Fatal(err)
			}
		}
	})
}
