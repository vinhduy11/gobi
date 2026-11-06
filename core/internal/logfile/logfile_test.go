package logfile

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRotationKeepsFourOldFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", "gobid.log")
	w, err := Open(path, 100, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	line := strings.Repeat("x", 59) + "\n" // two lines do not fit in 100 bytes
	for i := 0; i < 8; i++ {
		if _, err := w.Write([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	for _, suffix := range []string{"", ".1", ".2", ".3", ".4"} {
		if _, err := os.Stat(path + suffix); err != nil {
			t.Errorf("missing %s: %v", suffix, err)
		}
	}
	if _, err := os.Stat(path + ".5"); err == nil {
		t.Error("a fifth old file was kept")
	}
	if data, _ := os.ReadFile(path); len(data) > 100 {
		t.Errorf("current file is %d bytes, over the limit", len(data))
	}
}

func TestPermissions(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Gobi")
	path := filepath.Join(dir, "gobid.log")
	w, err := Open(path, 10, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	w.Write([]byte("0123456789abc\n"))
	w.Write([]byte("0123456789abc\n")) // forces a rotation
	for p, want := range map[string]os.FileMode{dir: 0o700, path: 0o600, path + ".1": 0o600} {
		info, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != want {
			t.Errorf("%s mode = %v, want %v", p, info.Mode().Perm(), want)
		}
	}
}

func TestOpenAppendsToAnExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	for _, text := range []string{"one\n", "two\n"} {
		w, err := Open(path, 1000, 4)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(text))
		w.Close()
	}
	if data, _ := os.ReadFile(path); string(data) != "one\ntwo\n" {
		t.Errorf("got %q", data)
	}
}

func TestRedact(t *testing.T) {
	tests := map[string]string{
		"/Users/me/secret-project":                      "secret-project",
		"open /Users/me/work/app/main.go: no such file": "open main.go: no such file",
		`path="/Users/me/work/app" failed`:              `path="app" failed`,
		"no paths here, a/b is relative":                "no paths here, a/b is relative",
		"exit status 1":                                 "exit status 1",
		"/":                                             "/",
	}
	for in, want := range tests {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHandlerRedactsPathsButNotStacks(t *testing.T) {
	var out bytes.Buffer
	logger := slog.New(NewHandler(&out, new(slog.LevelVar)))
	logger.Info("started", "root", "/Users/me/proj", "stack", "at /src/x/y.go:10")
	text := out.String()
	if strings.Contains(text, "/Users/me") || !strings.Contains(text, `"root":"proj"`) {
		t.Errorf("root not redacted: %s", text)
	}
	if !strings.Contains(text, "/src/x/y.go:10") {
		t.Errorf("stack was altered: %s", text)
	}
}

func TestRecoverLogsPanicWithStackAndSwallowsIt(t *testing.T) {
	var out bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&out, nil))
	func() {
		defer Recover(logger, "lsp client")
		panic("boom")
	}()
	text := out.String()
	for _, want := range []string{`"level":"ERROR"`, "boom", "lsp client", "goroutine", "logfile_test.go"} {
		if !strings.Contains(text, want) {
			t.Errorf("log lacks %q: %s", want, text)
		}
	}
}

func TestGuardReturnsNormally(t *testing.T) {
	logger := slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))
	called := false
	Guard(logger, "x", func(int) { called = true })(1)
	Guard(logger, "x", func(int) { panic("p") })(1)
	if !called {
		t.Error("guarded function not called")
	}
}
