//go:build unix

package daemon

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

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
