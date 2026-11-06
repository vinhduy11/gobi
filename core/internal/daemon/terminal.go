//go:build unix

package daemon

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

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

// serveTerminal attaches a login shell to the connection until either side ends it.
func serveTerminal(session *ipc.Session, logger *slog.Logger) {
	hello := session.Hello
	shell, err := pty.Start(pty.Options{Dir: hello.WorkspaceRoot, Shell: hello.Shell, Cols: 80, Rows: 24})
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

	for {
		payload, err := session.Reader.Read()
		if err != nil {
			return // the client went away: Close hangs up the shell
		}
		fields, err := wire.Parse(payload)
		if err != nil {
			return
		}
		var kind, cols, rows uint64
		var data []byte
		for _, field := range fields {
			switch field.Number {
			case terminalKind:
				kind = field.Uint
			case terminalData:
				data = field.Bytes
			case terminalCols:
				cols = field.Uint
			case terminalRows:
				rows = field.Uint
			}
		}
		switch kind {
		case terminalInput:
			if _, err := shell.Write(data); err != nil && err != io.ErrClosedPipe {
				<-finished
				return
			}
		case terminalResize:
			if cols > 0 && rows > 0 && cols < 1<<15 && rows < 1<<15 {
				shell.Resize(uint16(cols), uint16(rows))
			}
		}
	}
}
