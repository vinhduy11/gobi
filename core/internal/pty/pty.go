//go:build unix

// Package pty runs a login shell on a pseudo-terminal, which is what an IDE terminal panel attaches to.
package pty

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	creack "github.com/creack/pty"
)

// Options says where and how to start the shell.
type Options struct {
	Shell string // absolute path; empty means $SHELL, then /bin/sh
	Dir   string // working directory; must exist
	Env   []string
	Cols  uint16
	Rows  uint16
}

// Shell is a running shell. Read and Write talk to the terminal; Close ends the shell and what it started.
type Shell struct {
	cmd       *exec.Cmd
	terminal  *os.File
	closeOnce sync.Once
	waitOnce  sync.Once
	exitCode  int
}

// Start launches the shell as a login shell in its own session, with TERM=xterm-256color.
func Start(options Options) (*Shell, error) {
	shell := options.Shell
	if shell == "" {
		shell = os.Getenv("SHELL")
	}
	if shell == "" {
		shell = "/bin/sh"
	}
	if !filepath.IsAbs(shell) {
		return nil, fmt.Errorf("shell %q must be an absolute path", shell)
	}
	if info, err := os.Stat(options.Dir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("working directory %q is not a folder", options.Dir)
	}
	cols, rows := options.Cols, options.Rows
	if cols == 0 {
		cols = 80
	}
	if rows == 0 {
		rows = 24
	}

	command := exec.Command(shell, "-l")
	command.Dir = options.Dir
	env := options.Env
	if env == nil {
		env = os.Environ()
	}
	command.Env = append(env, "TERM=xterm-256color", "COLORTERM=truecolor")
	terminal, err := creack.StartWithSize(command, &creack.Winsize{Cols: cols, Rows: rows})
	if err != nil {
		return nil, err
	}
	return &Shell{cmd: command, terminal: terminal}, nil
}

func (s *Shell) Read(p []byte) (int, error)  { return s.terminal.Read(p) }
func (s *Shell) Write(p []byte) (int, error) { return s.terminal.Write(p) }

// Resize tells the terminal its new size in characters.
func (s *Shell) Resize(cols, rows uint16) error {
	return creack.Setsize(s.terminal, &creack.Winsize{Cols: cols, Rows: rows})
}

// Wait blocks until the shell exits and returns its exit code (128 plus the signal number when it was killed).
func (s *Shell) Wait() int {
	s.waitOnce.Do(func() {
		err := s.cmd.Wait()
		var exit *exec.ExitError
		switch {
		case err == nil:
			s.exitCode = 0
		case errors.As(err, &exit):
			if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
				s.exitCode = 128 + int(status.Signal())
			} else {
				s.exitCode = exit.ExitCode()
			}
		default:
			s.exitCode = -1
		}
	})
	return s.exitCode
}

// Close hangs up the terminal, signals the shell's whole process group, and force-kills it after a short grace period.
func (s *Shell) Close() error {
	s.closeOnce.Do(func() {
		if s.cmd.Process != nil {
			group := -s.cmd.Process.Pid
			syscall.Kill(group, syscall.SIGHUP)
			time.AfterFunc(2*time.Second, func() { syscall.Kill(group, syscall.SIGKILL) })
		}
		s.terminal.Close()
	})
	return nil
}
