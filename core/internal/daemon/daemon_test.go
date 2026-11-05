//go:build unix

package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/toolchain"
)

var fakeBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "fakelsp")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fakeBinary = filepath.Join(dir, "fakelsp")
	if output, err := exec.Command("go", "build", "-o", fakeBinary, "../lsp/fakelsp").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build fakelsp: %v\n%s", err, output)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func startDaemon(t *testing.T, command []string) (socketPath string, stop func() error) {
	t.Helper()
	socketDir, err := os.MkdirTemp("", "gd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })
	socketDir = filepath.Join(socketDir, "d")

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- Run(ctx, Config{
			SocketDir:     socketDir,
			ServerCommand: command,
			Logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		})
	}()
	socketPath = filepath.Join(socketDir, ipc.SocketName)
	waitUntil(t, "the daemon socket", func() bool { _, err := os.Stat(socketPath); return err == nil })
	return socketPath, func() error {
		cancel()
		select {
		case err := <-done:
			return err
		case <-time.After(10 * time.Second):
			return fmt.Errorf("daemon did not stop")
		}
	}
}

func waitUntil(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// call sends one LSP request over a session and returns the raw response.
func call(t *testing.T, session *ipc.Session, id int, method string, params any) map[string]json.RawMessage {
	t.Helper()
	encoded, _ := json.Marshal(params)
	request, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(encoded)})
	if err := session.Writer.Write(request); err != nil {
		t.Fatal(err)
	}
	for {
		payload, err := session.Reader.Read()
		if err != nil {
			t.Fatalf("reading %s response: %v", method, err)
		}
		var response map[string]json.RawMessage
		json.Unmarshal(payload, &response)
		if string(response["id"]) == fmt.Sprint(id) {
			return response
		}
	}
}

func TestDaemonServesLSPChannelEndToEnd(t *testing.T) {
	socketPath, stop := startDaemon(t, []string{fakeBinary})

	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "lsp", WorkspaceRoot: "/work/hello"})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	if response := call(t, session, 1, "initialize", map[string]any{"capabilities": map[string]any{}}); response["error"] != nil {
		t.Fatalf("initialize: %s", response["error"])
	}
	response := call(t, session, 2, "fake/env", nil)
	if !strings.Contains(string(response["result"]), `"local"`) {
		t.Fatalf("an untrusted workspace (the default) must run with GOTOOLCHAIN=local, got %s", response["result"])
	}

	if err := stop(); err != nil {
		t.Fatalf("daemon shutdown: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(socketPath), ipc.SocketName)); !os.IsNotExist(err) {
		t.Fatalf("socket must be removed on shutdown, stat err: %v", err)
	}
}

func TestDaemonReportsMissingLanguageServerWithoutDying(t *testing.T) {
	socketPath, stop := startDaemon(t, []string{"/nonexistent/gopls"})
	defer stop()

	for attempt := 0; attempt < 2; attempt++ {
		session, err := ipc.Dial(socketPath, ipc.Hello{Channel: "lsp", WorkspaceRoot: "/work/hello"})
		if err != nil {
			t.Fatalf("attempt %d: the daemon must stay up: %v", attempt, err)
		}
		response := call(t, session, 1, "initialize", map[string]any{})
		session.Close()
		if !strings.Contains(string(response["error"]), "unavailable") {
			t.Fatalf("attempt %d: want an 'unavailable' error, got %s", attempt, response["error"])
		}
	}
}

func TestDaemonRefusesASecondInstance(t *testing.T) {
	socketPath, stop := startDaemon(t, []string{fakeBinary})
	defer stop()

	err := Run(context.Background(), Config{SocketDir: filepath.Dir(socketPath), ServerCommand: []string{fakeBinary}})
	if err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("want an already-running error, got %v", err)
	}
}

// TestRealGopls drives the real gopls through the daemon. Opt in with GOBI_REAL_GOPLS=1.
func TestRealGopls(t *testing.T) {
	if os.Getenv("GOBI_REAL_GOPLS") != "1" {
		t.Skip("set GOBI_REAL_GOPLS=1 to run against the installed gopls")
	}
	goplsPath, err := toolchain.FromOS().Find("gopls")
	if err != nil {
		t.Skipf("gopls not installed: %v", err)
	}
	root, err := filepath.Abs("testdata/hello")
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile(filepath.Join(root, "main.go"))
	if err != nil {
		t.Fatal(err)
	}

	socketPath, stop := startDaemon(t, []string{goplsPath})
	defer stop()
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "lsp", WorkspaceRoot: root, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()

	if response := call(t, session, 1, "initialize", map[string]any{"capabilities": map[string]any{}}); response["error"] != nil {
		t.Fatalf("initialize: %s", response["error"])
	}
	uri := "file://" + filepath.Join(root, "main.go")
	opened, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": map[string]any{
		"textDocument": map[string]any{"uri": uri, "languageId": "go", "version": 1, "text": string(source)},
	}})
	if err := session.Writer.Write(opened); err != nil {
		t.Fatal(err)
	}

	// line 5 (0-based) is `func Greet(...)`; character 6 is inside "Greet"
	hover := call(t, session, 2, "textDocument/hover", map[string]any{
		"textDocument": map[string]any{"uri": uri},
		"position":     map[string]int{"line": 5, "character": 6},
	})
	if hover["error"] != nil || !strings.Contains(string(hover["result"]), "Greet") {
		t.Fatalf("hover: error=%s result=%s", hover["error"], hover["result"])
	}
}
