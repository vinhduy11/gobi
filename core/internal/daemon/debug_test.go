//go:build unix

package daemon

import (
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"gobi/core/internal/ipc"
)

var fakeDAPBinary string

func buildFakeDAP(t *testing.T) string {
	t.Helper()
	if fakeDAPBinary == "" {
		// Next to fakelsp, which lives for the whole test run (a t.TempDir would vanish when this test ends).
		fakeDAPBinary = filepath.Join(filepath.Dir(fakeBinary), "fakedap")
		if out, err := exec.Command("go", "build", "-o", fakeDAPBinary, "../debugger/fakedap").CombinedOutput(); err != nil {
			t.Fatalf("build fakedap: %v\n%s", err, out)
		}
	}
	return fakeDAPBinary
}

func TestDapChannelCarriesMessagesToTheDebugger(t *testing.T) {
	fake := buildFakeDAP(t)
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}, "dap": {fake}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "dap", WorkspaceRoot: t.TempDir(), Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.Writer.Write([]byte(`{"seq":1}`)); err != nil {
		t.Fatal(err)
	}
	for {
		got, err := session.Reader.Read()
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(got), `"type":"event"`) {
			continue // output events from the adapter's stdout are interleaved
		}
		if string(got) != `{"seq":1}` {
			t.Fatalf("echo = %q", got)
		}
		break
	}
}

func TestDapChannelIsOffInRestrictedMode(t *testing.T) {
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}, "dap": {buildFakeDAP(t)}})
	t.Cleanup(func() { stop() })
	if _, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "dap", WorkspaceRoot: t.TempDir(), Trusted: false}); err == nil {
		t.Fatal("debugging runs the program; it must be refused for an untrusted workspace")
	}
}

func TestDapChannelSaysWhenNoDebuggerIsInstalled(t *testing.T) {
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	_, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "dap", WorkspaceRoot: t.TempDir(), Trusted: true})
	if err == nil {
		t.Fatal("expected a refusal that names the missing debugger")
	}

}

func TestDapChannelTurnsTheProgramsOutputIntoOutputEvents(t *testing.T) {
	fake := buildFakeDAP(t)
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}, "dap": {fake}})
	t.Cleanup(func() { stop() })
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "dap", WorkspaceRoot: t.TempDir(), Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	var sawStdout, sawStderr bool
	for !(sawStdout && sawStderr) {
		payload, err := session.Reader.Read()
		if err != nil {
			t.Fatalf("no output events (stdout %v, stderr %v): %v", sawStdout, sawStderr, err)
		}
		var message struct {
			Type  string `json:"type"`
			Event string `json:"event"`
			Body  struct {
				Category string `json:"category"`
				Output   string `json:"output"`
			} `json:"body"`
		}
		if json.Unmarshal(payload, &message) != nil || message.Type != "event" || message.Event != "output" {
			continue
		}
		sawStdout = sawStdout || (message.Body.Category == "stdout" && strings.Contains(message.Body.Output, "program says hi"))
		sawStderr = sawStderr || (message.Body.Category == "stderr" && strings.Contains(message.Body.Output, "err line"))
	}
}
