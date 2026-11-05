//go:build unix

package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"gobi/core/internal/ipc"
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

func TestControlCreatesAProjectAndInspectsIt(t *testing.T) {
	session := controlSession(t)
	location := t.TempDir()

	response := call(t, session, 1, "project/new", map[string]any{
		"template": "library", "name": "widget", "location": location, "module_path": "example.com/widget",
	})
	if response["error"] != nil {
		t.Fatalf("project/new failed: %s", response["error"])
	}
	var created struct{ Root, Kind string }
	json.Unmarshal(response["result"], &created)
	if created.Root != filepath.Join(location, "widget") || created.Kind != "module" {
		t.Fatalf("unexpected result %s", response["result"])
	}
	if _, err := os.Stat(filepath.Join(created.Root, "widget.go")); err != nil {
		t.Fatal(err)
	}

	response = call(t, session, 2, "project/open", map[string]any{"path": created.Root})
	var opened struct {
		Kind       string
		ModulePath string `json:"module_path"`
	}
	json.Unmarshal(response["result"], &opened)
	if opened.Kind != "module" || opened.ModulePath != "example.com/widget" {
		t.Fatalf("project/open = %s", response["result"])
	}
}

func TestControlAnswersBadRequestsWithErrorsAndStaysUsable(t *testing.T) {
	session := controlSession(t)

	if response := call(t, session, 1, "project/new", map[string]any{"template": "cli", "name": "../evil", "location": t.TempDir()}); response["error"] == nil {
		t.Fatal("a name with a slash must be an error")
	}
	if response := call(t, session, 2, "project/clone", map[string]any{"url": "ext::sh -c id", "location": t.TempDir()}); response["error"] == nil {
		t.Fatal("an unsafe clone URL must be an error")
	}
	if response := call(t, session, 3, "project/unknown", map[string]any{}); response["error"] == nil {
		t.Fatal("an unknown method must be an error")
	}
	// The connection still works after errors.
	response := call(t, session, 4, "project/open", map[string]any{"path": t.TempDir()})
	if response["error"] != nil {
		t.Fatalf("project/open after errors: %s", response["error"])
	}
}

func TestControlImportAddsAModuleToAPlainFolder(t *testing.T) {
	session := controlSession(t)
	dir := filepath.Join(t.TempDir(), "legacy")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\n\nfunc main() {}\n"), 0o644)

	response := call(t, session, 1, "project/import", map[string]any{"path": dir})
	if response["error"] != nil {
		t.Fatalf("project/import failed: %s", response["error"])
	}
	if _, err := os.Stat(filepath.Join(dir, "go.mod")); err != nil {
		t.Fatal(err)
	}
}
