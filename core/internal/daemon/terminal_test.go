//go:build unix

package daemon

import (
	"strings"
	"testing"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/wire"
)

func startTerminal(t *testing.T, trusted bool) (*ipc.Session, error) {
	t.Helper()
	t.Setenv("SHELL", "/bin/sh")
	socketPath, stop := startDaemon(t, map[string][]string{"go": {fakeBinary}})
	t.Cleanup(func() { stop() })
	return ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "pty", WorkspaceRoot: t.TempDir(), Trusted: trusted})
}

func sendInput(t *testing.T, session *ipc.Session, text string) {
	t.Helper()
	var message wire.Writer
	message.Uint(terminalKind, terminalInput)
	message.Raw(terminalData, []byte(text))
	if err := session.Writer.Write(message.Bytes()); err != nil {
		t.Fatal(err)
	}
}

// readUntilExit collects output until the exit message and returns the output and the exit code.
func readUntilExit(t *testing.T, session *ipc.Session) (string, uint64) {
	t.Helper()
	var output strings.Builder
	deadline := time.After(15 * time.Second)
	for {
		type result struct {
			payload []byte
			err     error
		}
		received := make(chan result, 1)
		go func() {
			payload, err := session.Reader.Read()
			received <- result{payload, err}
		}()
		select {
		case <-deadline:
			t.Fatalf("no exit message; output so far %q", output.String())
		case r := <-received:
			if r.err != nil {
				t.Fatalf("connection ended before an exit message: %v (output %q)", r.err, output.String())
			}
			fields, err := wire.Parse(r.payload)
			if err != nil {
				t.Fatal(err)
			}
			var kind, code uint64
			var data []byte
			for _, field := range fields {
				switch field.Number {
				case terminalKind:
					kind = field.Uint
				case terminalData:
					data = field.Bytes
				case terminalExitCode:
					code = field.Uint
				}
			}
			if kind == terminalOutput {
				output.Write(data)
			}
			if kind == terminalExit {
				return output.String(), code
			}
		}
	}
}

func TestTerminalRunsCommandsAndReportsTheExitCode(t *testing.T) {
	session, err := startTerminal(t, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	sendInput(t, session, "echo result-$((1+2))\nexit 4\n")
	output, code := readUntilExit(t, session)
	if !strings.Contains(output, "result-3") || code != 4 {
		t.Fatalf("output %q, exit code %d; want result-3 and 4", output, code)
	}
}

func TestTerminalResizeReachesTheShell(t *testing.T) {
	session, err := startTerminal(t, true)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	var resize wire.Writer
	resize.Uint(terminalKind, terminalResize)
	resize.Uint(terminalCols, 101)
	resize.Uint(terminalRows, 31)
	if err := session.Writer.Write(resize.Bytes()); err != nil {
		t.Fatal(err)
	}
	sendInput(t, session, "stty size\nexit 0\n")
	output, _ := readUntilExit(t, session)
	if !strings.Contains(output, "31 101") {
		t.Fatalf("stty size should print 31 101, output %q", output)
	}
}

func TestTerminalIsRefusedInAnUntrustedWorkspace(t *testing.T) {
	_, err := startTerminal(t, false)
	if err == nil || !strings.Contains(err.Error(), "Restricted") {
		t.Fatalf("an untrusted workspace must not get a terminal, got %v", err)
	}
}

func TestTerminalStartsAtTheSizeOfTheFirstMessage(t *testing.T) {
	var resize wire.Writer
	resize.Uint(terminalKind, terminalResize)
	resize.Uint(terminalCols, 190)
	resize.Uint(terminalRows, 40)
	if cols, rows := initialTerminalSize(resize.Bytes()); cols != 190 || rows != 40 {
		t.Fatalf("a resize first starts the shell at 190x40, got %dx%d", cols, rows)
	}
	var input wire.Writer
	input.Uint(terminalKind, terminalInput)
	input.Raw(terminalData, []byte("ls\n"))
	for name, first := range map[string][]byte{"input": input.Bytes(), "nothing": nil, "garbage": {0xff, 0xff}} {
		if cols, rows := initialTerminalSize(first); cols != 80 || rows != 24 {
			t.Fatalf("%s first starts the shell at 80x24, got %dx%d", name, cols, rows)
		}
	}
	var huge wire.Writer
	huge.Uint(terminalKind, terminalResize)
	huge.Uint(terminalCols, 1<<20)
	huge.Uint(terminalRows, 24)
	if cols, rows := initialTerminalSize(huge.Bytes()); cols != 80 || rows != 24 {
		t.Fatalf("an impossible size falls back to 80x24, got %dx%d", cols, rows)
	}
}
