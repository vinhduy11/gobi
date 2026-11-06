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

func TestCaptureFetchesTheProfileFromALoopbackServer(t *testing.T) {
	var path, query string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, query = r.URL.Path, r.URL.RawQuery
		w.Write([]byte("profile bytes"))
	}))
	defer server.Close()
	out := filepath.Join(t.TempDir(), "cpu.pprof")
	if err := Capture(context.Background(), strings.TrimPrefix(server.URL, "http://"), "cpu", 2, out); err != nil {
		t.Fatal(err)
	}
	if path != "/debug/pprof/profile" || query != "seconds=2" {
		t.Errorf("asked for %s?%s", path, query)
	}
	if got, _ := os.ReadFile(out); string(got) != "profile bytes" {
		t.Errorf("file = %q", got)
	}
	if err := Capture(context.Background(), strings.TrimPrefix(server.URL, "http://"), "heap", 0, filepath.Join(filepath.Dir(out), "heap.pprof")); err != nil || path != "/debug/pprof/heap" {
		t.Errorf("heap: %v %s", err, path)
	}
}

func TestCaptureRefusesWhatIsNotLocalOrNotValid(t *testing.T) {
	out := filepath.Join(t.TempDir(), "x.pprof")
	cases := map[string][4]any{
		"remote host":    {"example.com:6060", "cpu", 5, out},
		"no port":        {"localhost", "cpu", 5, out},
		"bad kind":       {"localhost:6060", "../etc", 5, out},
		"too long":       {"localhost:6060", "cpu", 500, out},
		"relative out":   {"localhost:6060", "cpu", 5, "x.pprof"},
		"not a pprof":    {"localhost:6060", "cpu", 5, filepath.Join(t.TempDir(), "x.txt")},
		"userinfo trick": {"localhost@example.com:6060", "cpu", 5, out},
	}
	for name, c := range cases {
		if err := Capture(context.Background(), c[0].(string), c[1].(string), c[2].(int), c[3].(string)); err == nil {
			t.Errorf("%s: expected a refusal", name)
		}
	}
}

func TestCaptureReportsAServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "profiling not on", 404) }))
	defer server.Close()
	out := filepath.Join(t.TempDir(), "x.pprof")
	err := Capture(context.Background(), strings.TrimPrefix(server.URL, "http://"), "cpu", 1, out)
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("err = %v", err)
	}
	if _, statErr := os.Stat(out); statErr == nil {
		t.Error("nothing should be written when the server fails")
	}
}
