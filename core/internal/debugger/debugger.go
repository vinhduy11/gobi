//go:build unix

// Package debugger starts a Debug Adapter Protocol server (dlv dap) for a project and hands back a connection to it.
package debugger

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const announce = "listening at: "

// Chunk is some of what the adapter, and the program it runs, wrote to stdout or stderr. Delve does not forward the debuggee's
// output as DAP events, so the caller turns these into output events.
type Chunk struct {
	Stderr bool
	Data   []byte
}

// Session is a running adapter and the connection to it.
type Session struct {
	cmd    *exec.Cmd
	conn   net.Conn
	output chan Chunk
}

// Output delivers the adapter's stdout (after its address line) and stderr. It is closed when the adapter ends; chunks are
// dropped rather than block the adapter when nobody reads.
func (s *Session) Output() <-chan Chunk { return s.output }

// Conn carries Content-Length framed DAP messages in both directions.
func (s *Session) Conn() net.Conn { return s.conn }

// Close ends the connection and the adapter (and anything it started).
func (s *Session) Close() {
	s.conn.Close()
	if s.cmd.Process != nil {
		syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
	}
	s.cmd.Wait()
}

// Start runs command in dir. The adapter must print "...listening at: HOST:PORT" on its output (dlv dap does); Start waits up
// to wait for that line, then connects.
func Start(command []string, dir string, wait time.Duration) (*Session, error) {
	if len(command) == 0 {
		return nil, errors.New("no debugger command is configured")
	}
	if !filepath.IsAbs(dir) {
		return nil, fmt.Errorf("directory must be absolute: %q", dir)
	}
	cmd := exec.Command(command[0], command[1:]...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start debugger: %w", err)
	}
	kill := func() {
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		cmd.Wait()
	}

	output := make(chan Chunk, 256)
	var pumps sync.WaitGroup
	pump := func(source io.Reader, stderr bool) {
		defer pumps.Done()
		buffer := make([]byte, 4096)
		for {
			n, err := source.Read(buffer)
			if n > 0 {
				select {
				case output <- Chunk{Stderr: stderr, Data: append([]byte(nil), buffer[:n]...)}:
				default: // nobody is reading; drop it
				}
			}
			if err != nil {
				return
			}
		}
	}
	pumps.Add(2) // stderr, and stdout once the address line is read
	go pump(stderr, true)
	go func() { pumps.Wait(); close(output) }()

	address := make(chan string, 1)
	go func() {
		reader := bufio.NewReader(stdout)
		found := false
		for !found {
			line, err := reader.ReadString('\n')
			if i := strings.Index(line, announce); i >= 0 {
				address <- strings.TrimSpace(line[i+len(announce):])
				found = true
			}
			if err != nil {
				break
			}
		}
		if !found {
			close(address)
			pumps.Done()
			return
		}
		pump(reader, false)
	}()
	select {
	case addr, ok := <-address:
		if !ok {
			kill()
			return nil, errors.New("the debugger exited before it was ready")
		}
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err != nil {
			kill()
			return nil, fmt.Errorf("connect to the debugger: %w", err)
		}
		return &Session{cmd: cmd, conn: conn, output: output}, nil
	case <-time.After(wait):
		kill()
		return nil, errors.New("the debugger did not become ready in time")
	}
}
