//go:build unix

package pty

import (
	"bytes"
	"io"
	"strings"
	"testing"
	"time"
)

// readUntil reads from the shell until the output contains want, or fails after a timeout.
func readUntil(t *testing.T, shell *Shell, want string) string {
	t.Helper()
	var collected bytes.Buffer
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 4096)
		for {
			count, err := shell.Read(buffer)
			collected.Write(buffer[:count])
			if strings.Contains(collected.String(), want) || err != nil {
				return
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		shell.Close()
		<-done
		t.Fatalf("timed out waiting for %q, got %q", want, collected.String())
	}
	if !strings.Contains(collected.String(), want) {
		t.Fatalf("output %q does not contain %q", collected.String(), want)
	}
	return collected.String()
}

func start(t *testing.T) *Shell {
	t.Helper()
	shell, err := Start(Options{Shell: "/bin/sh", Dir: t.TempDir(), Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { shell.Close() })
	return shell
}

func TestShellRunsCommandsAndReportsTheExitCode(t *testing.T) {
	shell := start(t)
	if _, err := io.WriteString(shell, "echo result-$((1+2))\nexit 3\n"); err != nil {
		t.Fatal(err)
	}
	readUntil(t, shell, "result-3")
	// A real client keeps reading until EOF; a shell cannot finish exiting while its output sits unread.
	go io.Copy(io.Discard, shell)
	if code := shell.Wait(); code != 3 {
		t.Fatalf("exit code %d, want 3", code)
	}
}

func TestShellStartsInTheGivenFolderWithATerminalType(t *testing.T) {
	dir := t.TempDir()
	shell, err := Start(Options{Shell: "/bin/sh", Dir: dir, Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	defer shell.Close()
	io.WriteString(shell, "pwd; echo term=$TERM\n")
	output := readUntil(t, shell, "term=xterm-256color")
	if !strings.Contains(output, dir) && !strings.Contains(output, strings.TrimPrefix(dir, "/private")) {
		t.Fatalf("shell did not start in %s: %q", dir, output)
	}
}

func TestResizeChangesTheTerminalSize(t *testing.T) {
	shell := start(t)
	if err := shell.Resize(100, 30); err != nil {
		t.Fatal(err)
	}
	io.WriteString(shell, "stty size\n")
	readUntil(t, shell, "30 100")
}

func TestCloseEndsALongRunningProgram(t *testing.T) {
	shell := start(t)
	io.WriteString(shell, "sleep 300\n")
	time.Sleep(200 * time.Millisecond)
	done := make(chan int, 1)
	go func() { done <- shell.Wait() }()
	shell.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not end the shell and its child")
	}
}

func TestStartRefusesAMissingFolderAndARelativeShell(t *testing.T) {
	if _, err := Start(Options{Shell: "/bin/sh", Dir: "/definitely/not/here"}); err == nil {
		t.Fatal("a missing folder must be an error")
	}
	if _, err := Start(Options{Shell: "sh", Dir: t.TempDir()}); err == nil {
		t.Fatal("a shell that is not an absolute path must be refused")
	}
}
