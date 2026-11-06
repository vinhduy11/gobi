package daemon

import (
	"bytes"
	"os"
	"path/filepath"
	rpprof "runtime/pprof"
	"strings"
	"testing"

	"gobi/core/internal/wire"
)

func writeHeapProfile(t *testing.T) string {
	t.Helper()
	var heapBytes bytes.Buffer
	if err := rpprof.Lookup("heap").WriteTo(&heapBytes, 0); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "heap.pprof")
	if err := os.WriteFile(path, heapBytes.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProfileLinesAndDiff(t *testing.T) {
	session := controlSession(t)
	path := writeHeapProfile(t)
	_, failure := controlCall(t, session, 1, "profile/lines", func(w *wire.Writer) { w.String(1, "x.pprof"); w.String(3, "main.main") })
	if !strings.Contains(failure, "absolute") {
		t.Errorf("failure = %q", failure)
	}
	if _, failure = controlCall(t, session, 2, "profile/lines", func(w *wire.Writer) { w.String(1, path); w.String(3, "no.such") }); failure != "" {
		t.Errorf("an unknown function is an empty answer, got %q", failure)
	}
	_, failure = controlCall(t, session, 3, "profile/diff", func(w *wire.Writer) { w.String(1, path); w.String(2, "rel.pprof") })
	if !strings.Contains(failure, "absolute") {
		t.Errorf("failure = %q", failure)
	}
	result, failure := controlCall(t, session, 4, "profile/diff", func(w *wire.Writer) { w.String(1, path); w.String(2, path); w.String(3, "alloc_space") })
	if failure != "" {
		t.Fatal(failure)
	}
	if string(result[1].Bytes) != "alloc_space" || string(result[2].Bytes) != "bytes" {
		t.Errorf("type/unit = %q %q", result[1].Bytes, result[2].Bytes)
	}
	if _, failure = controlCall(t, session, 5, "profile/diff", func(w *wire.Writer) { w.String(1, path); w.String(2, path); w.String(3, "nope") }); !strings.Contains(failure, "nope") {
		t.Errorf("failure = %q", failure)
	}
}
