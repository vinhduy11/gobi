//go:build unix

package daemon

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/pty"
	"gobi/core/internal/wire"
)

// Field numbers of the pty channel messages (protobuf wire format, see package wire). Never reuse a number.
//
//	client to server: 1 kind (1 input, 2 resize), 2 data (input bytes), 3 columns, 4 rows
//	server to client: 1 kind (1 output, 3 exit), 2 data (output bytes), 5 exit code
//
// The shell starts in the handshake's workspace_root when the first message arrives; a resize may come first.
const (
	terminalKind     = 1
	terminalData     = 2
	terminalCols     = 3
	terminalRows     = 4
	terminalExitCode = 5

	terminalInput  = 1
	terminalResize = 2
	terminalOutput = 1
	terminalExit   = 3

	terminalReadSize = 32 << 10
)

// terminalAdmit refuses a terminal in a workspace the user has not trusted: a shell runs commands as the user.
func terminalAdmit(hello ipc.Hello) string {
	if hello.Channel == "pty" && !hello.Trusted {
		return "terminals are off in Restricted Mode; trust the project first"
	}
	if reason := shellAdmit(hello, shellsFile); reason != "" {
		return reason
	}
	return runAdmit(hello)
}

const shellsFile = "/etc/shells"

// listedShells reads the shells a user may choose: absolute paths in the shells file that exist, once each.
func listedShells(file string) []string {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	var shells []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !filepath.IsAbs(line) || seen[line] {
			continue
		}
		if info, err := os.Stat(line); err == nil && !info.IsDir() {
			seen[line] = true
			shells = append(shells, line)
		}
	}
	return shells
}

// shellAdmit refuses a terminal that asks for a shell the system does not list, so the handshake cannot start any program.
func shellAdmit(hello ipc.Hello, file string) string {
	if hello.Channel != "pty" || hello.Shell == "" {
		return ""
	}
	for _, shell := range listedShells(file) {
		if shell == hello.Shell {
			return ""
		}
	}
	return hello.Shell + " is not listed in /etc/shells"
}

// terminalMessage is one parsed client message.
type terminalMessage struct {
	kind       uint64
	cols, rows uint64
	data       []byte
}

func parseTerminalMessage(payload []byte) (terminalMessage, error) {
	fields, err := wire.Parse(payload)
	if err != nil {
		return terminalMessage{}, err
	}
	var m terminalMessage
	for _, field := range fields {
		switch field.Number {
		case terminalKind:
			m.kind = field.Uint
		case terminalData:
			m.data = field.Bytes
		case terminalCols:
			m.cols = field.Uint
		case terminalRows:
			m.rows = field.Uint
		}
	}
	return m, nil
}

func validTerminalSize(cols, rows uint64) bool {
	return cols > 0 && rows > 0 && cols < 1<<15 && rows < 1<<15
}

const (
	defaultTerminalCols = 80
	defaultTerminalRows = 24
	// terminalStartWait is how long the shell waits for the client's first message (its size) before starting at the default size.
	terminalStartWait = time.Second
)

// initialTerminalSize is the size the shell starts at: the client's, when its first message is a resize. A shell that starts at the
// wrong size and is resized afterwards has already laid out its prompt for it (zsh pads its end-of-line mark to the width).
func initialTerminalSize(first []byte) (cols, rows uint16) {
	if m, err := parseTerminalMessage(first); err == nil && m.kind == terminalResize && validTerminalSize(m.cols, m.rows) {
		return uint16(m.cols), uint16(m.rows)
	}
	return defaultTerminalCols, defaultTerminalRows
}

// serveTerminal attaches a login shell to the connection until either side ends it. The shell starts when the first message
// arrives (a resize, from gobi), so it starts at the right size.
func serveTerminal(session *ipc.Session, logger *slog.Logger) {
	hello := session.Hello
	done := make(chan struct{})
	defer close(done)
	messages := make(chan []byte)
	go func() {
		defer close(messages)
		for {
			payload, err := session.Reader.Read()
			if err != nil {
				return // the client went away
			}
			select {
			case messages <- payload:
			case <-done:
				return
			}
		}
	}()

	var first []byte
	select {
	case payload, ok := <-messages:
		if !ok {
			return
		}
		first = payload
	case <-time.After(terminalStartWait):
	}

	cols, rows := initialTerminalSize(first)
	shell, err := pty.Start(pty.Options{Dir: hello.WorkspaceRoot, Shell: hello.Shell, Cols: cols, Rows: rows})
	if err != nil {
		logger.Info("terminal could not start", "root", filepath.Base(hello.WorkspaceRoot), "error", err)
		var message wire.Writer
		message.Uint(terminalKind, terminalExit)
		message.Uint(terminalExitCode, 127)
		message.Raw(terminalData, []byte(err.Error()+"\r\n"))
		session.Writer.Write(message.Bytes())
		return
	}
	logger.Info("terminal started", "root", filepath.Base(hello.WorkspaceRoot))
	defer shell.Close()

	finished := make(chan struct{})
	go func() {
		defer close(finished)
		buffer := make([]byte, terminalReadSize)
		for {
			count, err := shell.Read(buffer)
			if count > 0 {
				var message wire.Writer
				message.Uint(terminalKind, terminalOutput)
				message.Raw(terminalData, buffer[:count])
				if session.Writer.Write(message.Bytes()) != nil {
					return
				}
			}
			if err != nil {
				break
			}
		}
		var message wire.Writer
		message.Uint(terminalKind, terminalExit)
		message.Uint(terminalExitCode, uint64(shell.Wait()))
		session.Writer.Write(message.Bytes())
	}()

	// handle applies one client message; false ends the session.
	handle := func(payload []byte) bool {
		m, err := parseTerminalMessage(payload)
		if err != nil {
			return false
		}
		switch m.kind {
		case terminalInput:
			if _, err := shell.Write(m.data); err != nil && err != io.ErrClosedPipe {
				<-finished
				return false
			}
		case terminalResize:
			if validTerminalSize(m.cols, m.rows) {
				shell.Resize(uint16(m.cols), uint16(m.rows))
			}
		}
		return true
	}
	if first != nil && !handle(first) {
		return
	}
	for payload := range messages {
		if !handle(payload) {
			return
		}
	}
}
