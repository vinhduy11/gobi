package pprof

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCaptureNeverOverwritesAnExistingFile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("second")) }))
	defer server.Close()
	out := filepath.Join(t.TempDir(), "keep.pprof")
	if err := os.WriteFile(out, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := Capture(context.Background(), strings.TrimPrefix(server.URL, "http://"), "heap", 0, out)
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Errorf("err = %v, want an already exists error", err)
	}
	if got, _ := os.ReadFile(out); string(got) != "first" {
		t.Errorf("file = %q, want the first capture intact", got)
	}
}
