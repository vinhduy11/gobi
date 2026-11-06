//go:build unix

package daemon

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	rpprof "runtime/pprof"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

func controlSession(t *testing.T) *ipc.Session {
	t.Helper()
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "control"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

// controlCall sends one binary request and returns the result's fields, or the error message.
func controlCall(t *testing.T, session *ipc.Session, id uint64, method string, params func(*wire.Writer)) (result map[int]wire.Field, failure string) {
	t.Helper()
	var request wire.Writer
	request.Uint(controlID, id)
	request.String(controlMethod, method)
	request.Message(controlBody, params)
	if err := session.Writer.Write(request.Bytes()); err != nil {
		t.Fatal(err)
	}
	payload, err := session.Reader.Read()
	if err != nil {
		t.Fatalf("reading the %s reply: %v", method, err)
	}
	fields, err := wire.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	result = map[int]wire.Field{}
	var replyID uint64
	for _, field := range fields {
		switch field.Number {
		case controlID:
			replyID = field.Uint
		case controlFailure:
			failure = string(field.Bytes)
		case controlBody:
			inner, err := wire.Parse(field.Bytes)
			if err != nil {
				t.Fatal(err)
			}
			for _, innerField := range inner {
				result[innerField.Number] = innerField
			}
		}
	}
	if replyID != id {
		t.Fatalf("reply id %d, want %d", replyID, id)
	}
	return result, failure
}

func TestControlCreatesAProjectAndInspectsIt(t *testing.T) {
	session := controlSession(t)
	location := t.TempDir()

	result, failure := controlCall(t, session, 1, "project/new", func(w *wire.Writer) {
		w.String(1, "library")
		w.String(2, "widget")
		w.String(3, location)
		w.String(4, "example.com/widget")
	})
	if failure != "" {
		t.Fatalf("project/new failed: %s", failure)
	}
	root := string(result[projectRoot].Bytes)
	if root != filepath.Join(location, "widget") || string(result[projectKind].Bytes) != "module" {
		t.Fatalf("unexpected result root=%q kind=%q", root, result[projectKind].Bytes)
	}
	if _, err := os.Stat(filepath.Join(root, "widget.go")); err != nil {
		t.Fatal(err)
	}

	result, failure = controlCall(t, session, 2, "project/open", func(w *wire.Writer) { w.String(1, root) })
	if failure != "" || string(result[projectKind].Bytes) != "module" || string(result[projectModule].Bytes) != "example.com/widget" {
		t.Fatalf("project/open = %v %q", result, failure)
	}
}

func TestControlAnswersBadRequestsWithErrorsAndStaysUsable(t *testing.T) {
	session := controlSession(t)

	if _, failure := controlCall(t, session, 1, "project/new", func(w *wire.Writer) {
		w.String(1, "cli")
		w.String(2, "../evil")
		w.String(3, t.TempDir())
	}); failure == "" {
		t.Fatal("a name with a slash must be an error")
	}
	if _, failure := controlCall(t, session, 2, "project/clone", func(w *wire.Writer) {
		w.String(1, "ext::sh -c id")
		w.String(2, t.TempDir())
	}); failure == "" {
		t.Fatal("an unsafe clone URL must be an error")
	}
	if _, failure := controlCall(t, session, 3, "project/unknown", func(*wire.Writer) {}); failure == "" {
		t.Fatal("an unknown method must be an error")
	}
	if _, failure := controlCall(t, session, 4, "project/open", func(w *wire.Writer) { w.String(1, t.TempDir()) }); failure != "" {
		t.Fatalf("project/open after errors: %s", failure)
	}
}

func TestControlImportAddsAModuleToAPlainFolder(t *testing.T) {
	session := controlSession(t)
	dir := filepath.Join(t.TempDir(), "legacy")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\n\nfunc main() {}\n"), 0o644)

	if _, failure := controlCall(t, session, 1, "project/import", func(w *wire.Writer) { w.String(1, dir) }); failure != "" {
		t.Fatalf("project/import failed: %s", failure)
	}
	if _, err := os.Stat(filepath.Join(dir, "go.mod")); err != nil {
		t.Fatal(err)
	}
}

// The Swift client builds the same bytes in its tests.
func TestControlRequestGoldenBytes(t *testing.T) {
	var request wire.Writer
	request.Uint(controlID, 1)
	request.String(controlMethod, "project/open")
	request.Message(controlBody, func(w *wire.Writer) { w.String(1, "/p") })
	want := []byte{0x08, 0x01, 0x12, 0x0c, 'p', 'r', 'o', 'j', 'e', 'c', 't', '/', 'o', 'p', 'e', 'n', 0x1a, 0x04, 0x0a, 0x02, '/', 'p'}
	if !bytes.Equal(request.Bytes(), want) {
		t.Fatalf("request bytes = % x, want % x", request.Bytes(), want)
	}
}

func TestControlRejectsAJSONRequest(t *testing.T) {
	session := controlSession(t)
	if err := session.Writer.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"project/open"}`)); err != nil {
		t.Fatal(err)
	}
	payload, err := session.Reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	fields, _ := wire.Parse(payload)
	var failure string
	for _, field := range fields {
		if field.Number == controlFailure {
			failure = string(field.Bytes)
		}
	}
	if failure == "" {
		t.Fatalf("a JSON request must get an error reply, got % x", payload)
	}
}

func TestControlPreviewListsTheFilesNewWouldWrite(t *testing.T) {
	session := controlSession(t)
	location := t.TempDir()
	params := func(w *wire.Writer) {
		w.String(1, "cli")
		w.String(2, "demo")
		w.String(3, location)
		w.String(4, "example.com/demo")
		w.Bool(7, true)
		w.Bool(8, true)
	}
	// controlCall keeps one field per number, so read the repeated files from a raw reply.
	var request wire.Writer
	request.Uint(controlID, 1)
	request.String(controlMethod, "project/preview")
	request.Message(controlBody, params)
	if err := session.Writer.Write(request.Bytes()); err != nil {
		t.Fatal(err)
	}
	payload, err := session.Reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	fields, _ := wire.Parse(payload)
	var files []string
	for _, field := range fields {
		if field.Number == controlBody {
			inner, _ := wire.Parse(field.Bytes)
			for _, innerField := range inner {
				if innerField.Number == projectFile {
					files = append(files, string(innerField.Bytes))
				}
			}
		}
	}
	want := ".env.example,.gitignore,README.md,go.mod,main.go,main_test.go"
	if strings.Join(files, ",") != want {
		t.Fatalf("preview files = %v, want %s", files, want)
	}
	if _, err := os.Stat(filepath.Join(location, "demo")); err == nil {
		t.Fatal("a preview must not create anything")
	}
}

func TestToolsCheckListsEveryTool(t *testing.T) {
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "tools/check", func(*wire.Writer) {})
	if failure != "" {
		t.Fatal(failure)
	}
	entry, err := wire.Parse(result[toolEntry].Bytes) // the map keeps the last entry: git
	if err != nil {
		t.Fatal(err)
	}
	if len(entry) == 0 || string(entry[0].Bytes) != "git" {
		t.Errorf("last entry = %+v", entry)
	}
}

func TestToolsInstallRefusesWhatItCannotInstall(t *testing.T) {
	session := controlSession(t)
	_, failure := controlCall(t, session, 1, "tools/install", func(w *wire.Writer) { w.String(1, "go") })
	if !strings.Contains(failure, "cannot be installed") {
		t.Errorf("failure = %q", failure)
	}
}

func TestToolchainInstallRefusesABadVersion(t *testing.T) {
	session := controlSession(t)
	_, failure := controlCall(t, session, 1, "toolchain/install", func(w *wire.Writer) { w.String(1, "1.25; rm -rf ~") })
	if !strings.Contains(failure, "not a Go version") {
		t.Errorf("failure = %q", failure)
	}
}

func TestProfileLoadRefusesARelativePathAndAMissingFile(t *testing.T) {
	session := controlSession(t)
	_, failure := controlCall(t, session, 1, "profile/load", func(w *wire.Writer) { w.String(1, "cpu.pprof") })
	if !strings.Contains(failure, "absolute") {
		t.Errorf("failure = %q", failure)
	}
	_, failure = controlCall(t, session, 2, "profile/load", func(w *wire.Writer) { w.String(1, filepath.Join(t.TempDir(), "nope.pprof")) })
	if failure == "" {
		t.Error("a missing file must fail")
	}
}

func TestProfileCaptureRefusesARemoteAddress(t *testing.T) {
	session := controlSession(t)
	_, failure := controlCall(t, session, 1, "profile/capture", func(w *wire.Writer) {
		w.String(1, "example.com:6060")
		w.String(2, "cpu")
		w.String(3, "5")
		w.String(4, filepath.Join(t.TempDir(), "x.pprof"))
	})
	if !strings.Contains(failure, "this machine") {
		t.Errorf("failure = %q", failure)
	}
}

func TestProfileLoadAnswersWithTreeAndTop(t *testing.T) {
	var buffer bytes.Buffer
	if err := rpprof.Lookup("heap").WriteTo(&buffer, 0); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "heap.pprof")
	if err := os.WriteFile(path, buffer.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "profile/load", func(w *wire.Writer) { w.String(1, path) })
	if failure != "" {
		t.Fatal(failure)
	}
	if len(result[1].Bytes) == 0 {
		t.Error("no sample types in the answer")
	}
	if _, ok := result[5]; !ok {
		t.Error("no tree nodes in the answer")
	}
}

func TestDaemonSettingsThroughTheControlHooks(t *testing.T) {
	level := new(slog.LevelVar)
	stopped := make(chan struct{})
	hooks := controlHooks{level: level, stop: func() { close(stopped) }, started: time.Unix(1700000000, 0)}

	var params wire.Writer
	params.String(1, "debug")
	if _, err := handleControl("daemon/loglevel", params.Bytes(), hooks); err != nil || level.Level() != slog.LevelDebug {
		t.Fatalf("level = %v, err = %v", level.Level(), err)
	}
	var bad wire.Writer
	bad.String(1, "loud")
	if _, err := handleControl("daemon/loglevel", bad.Bytes(), hooks); err == nil {
		t.Error("an unknown level must be refused")
	}
	if _, err := handleControl("daemon/loglevel", nil, controlHooks{}); err == nil {
		t.Error("without a level variable the level cannot change")
	}

	result, err := handleControl("daemon/status", nil, hooks)
	if err != nil {
		t.Fatal(err)
	}
	fields, _ := wire.Parse(result)
	got := map[int]wire.Field{}
	for _, f := range fields {
		got[f.Number] = f
	}
	if int(got[1].Uint) != os.Getpid() || string(got[3].Bytes) != "debug" || got[4].Uint != 1700000000 || len(got[2].Bytes) == 0 {
		t.Errorf("status = %+v", got)
	}

	if _, err := handleControl("daemon/stop", nil, hooks); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Error("stop was not called")
	}
}

func TestSearchFilesAnswersWithMatches(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "a.go"), []byte("one sum\ntwo\n"), 0o644)
	session := controlSession(t)
	result, failure := controlCall(t, session, 1, "search/files", func(w *wire.Writer) {
		w.String(1, "sum")
		w.String(9, root)
	})
	if failure != "" {
		t.Fatal(failure)
	}
	inner, err := wire.Parse(result[1].Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if string(inner[0].Bytes) != "a.go" || result[2].Uint != 1 {
		t.Errorf("result = %+v inner = %+v", result, inner)
	}
	_, failure = controlCall(t, session, 2, "search/files", func(w *wire.Writer) { w.String(1, "x"); w.String(9, "relative") })
	if !strings.Contains(failure, "absolute") {
		t.Errorf("failure = %q", failure)
	}
}
