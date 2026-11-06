//go:build unix

package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

func startRunChannel(t *testing.T, trusted bool) (*ipc.Session, string, error) {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"go.mod":       "module example.com/demo\n\ngo 1.22\n",
		"demo.go":      "package demo\n",
		"demo_test.go": "package demo\n\nimport \"testing\"\n\nfunc TestOK(t *testing.T) {}\n\nfunc TestBad(t *testing.T) { t.Fatal(\"boom\") }\n",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "run", WorkspaceRoot: dir, Trusted: trusted})
	return session, dir, err
}

func sendStart(t *testing.T, session *ipc.Session, command string, packages []string, filter string) {
	t.Helper()
	var message wire.Writer
	message.Uint(runKind, runStart)
	message.String(runCommand, command)
	for _, pattern := range packages {
		message.Raw(runPackage, []byte(pattern))
	}
	message.String(runFilter, filter)
	if err := session.Writer.Write(message.Bytes()); err != nil {
		t.Fatal(err)
	}
}

type runResult struct {
	output string
	tests  map[string]string
	exit   uint64
	text   string
}

func readRun(t *testing.T, session *ipc.Session) runResult {
	t.Helper()
	result := runResult{tests: map[string]string{}}
	deadline := time.After(90 * time.Second)
	for {
		received := make(chan []byte, 1)
		failed := make(chan error, 1)
		go func() {
			payload, err := session.Reader.Read()
			if err != nil {
				failed <- err
				return
			}
			received <- payload
		}()
		select {
		case <-deadline:
			t.Fatal("no exit message")
		case err := <-failed:
			t.Fatalf("connection ended: %v", err)
		case payload := <-received:
			fields, err := wire.Parse(payload)
			if err != nil {
				t.Fatal(err)
			}
			var kind, exit uint64
			var data []byte
			var action, test, text string
			for _, field := range fields {
				switch field.Number {
				case runKind:
					kind = field.Uint
				case runData:
					data = field.Bytes
				case runAction:
					action = string(field.Bytes)
				case runTest:
					test = string(field.Bytes)
				case runExitCode:
					exit = field.Uint
				case runMessage:
					text = string(field.Bytes)
				}
			}
			switch kind {
			case runOutputKind:
				result.output += string(data)
			case runTestKind:
				if test != "" && (action == "pass" || action == "fail" || action == "skip") {
					result.tests[test] = action
				}
			case runExitKind:
				result.exit = exit
				result.text = text
				return result
			}
		}
	}
}

func TestRunChannelStreamsATestRun(t *testing.T) {
	session, _, err := startRunChannel(t, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	sendStart(t, session, "test", []string{"./..."}, "")
	result := readRun(t, session)
	if result.tests["TestOK"] != "pass" || result.tests["TestBad"] != "fail" || result.exit != 1 {
		t.Fatalf("tests %v, exit %d", result.tests, result.exit)
	}
	if !strings.Contains(result.output, "boom") {
		t.Fatalf("the output panel text should hold the failure message, got %q", result.output)
	}
}

func TestRunChannelRefusesABadRequestAndStaysUsable(t *testing.T) {
	session, _, err := startRunChannel(t, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	sendStart(t, session, "install", nil, "")
	refused := readRun(t, session)
	if refused.exit != 125 || refused.text == "" {
		t.Fatalf("a bad request ends with exit 125 and a reason, got %d %q", refused.exit, refused.text)
	}
	sendStart(t, session, "test", []string{"./..."}, "^TestOK$")
	if again := readRun(t, session); again.exit != 0 || again.tests["TestOK"] != "pass" {
		t.Fatalf("after a refused request the channel must still work: %+v", again)
	}
}

func TestRunChannelIsRefusedInAnUntrustedWorkspace(t *testing.T) {
	_, _, err := startRunChannel(t, false)
	if err == nil || !strings.Contains(err.Error(), "Restricted") {
		t.Fatalf("running code needs trust, got %v", err)
	}
}
