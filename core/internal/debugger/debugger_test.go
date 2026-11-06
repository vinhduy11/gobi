//go:build unix

package debugger

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

var fakeBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "debugger")
	if err != nil {
		panic(err)
	}
	fakeBinary = filepath.Join(dir, "fakedap")
	if out, err := exec.Command("go", "build", "-o", fakeBinary, "./fakedap").CombinedOutput(); err != nil {
		panic(string(out))
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func TestStartConnectsToTheAnnouncedAddress(t *testing.T) {
	session, err := Start([]string{fakeBinary}, t.TempDir(), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := rpc.NewWriter(session.Conn()).Write([]byte(`{"seq":1,"type":"request","command":"initialize"}`)); err != nil {
		t.Fatal(err)
	}
	got, err := rpc.NewReader(session.Conn(), 1<<20).Read()
	if err != nil || string(got) != `{"seq":1,"type":"request","command":"initialize"}` {
		t.Fatalf("echo = %q, %v", got, err)
	}
}

func TestStartFailsWhenTheDebuggerNeverAnnounces(t *testing.T) {
	if _, err := Start([]string{fakeBinary, "silent"}, t.TempDir(), 300*time.Millisecond); err == nil {
		t.Fatal("expected a timeout")
	}
}

func TestStartFailsWhenThereIsNoCommand(t *testing.T) {
	if _, err := Start(nil, t.TempDir(), time.Second); err == nil {
		t.Fatal("expected an error for an empty command")
	}
}

func TestStartRefusesARelativeFolder(t *testing.T) {
	if _, err := Start([]string{fakeBinary}, "relative", time.Second); err == nil {
		t.Fatal("expected an error for a relative folder")
	}
}

func TestOutputCarriesWhatTheDebuggeePrints(t *testing.T) {
	session, err := Start([]string{fakeBinary}, t.TempDir(), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	got := map[bool]string{}
	deadline := time.After(5 * time.Second)
	for !(strings.Contains(got[false], "program says hi") && strings.Contains(got[true], "err line")) {
		select {
		case chunk := <-session.Output():
			got[chunk.Stderr] += string(chunk.Data)
		case <-deadline:
			t.Fatalf("output so far: %v", got)
		}
	}
}
