//go:build unix

// Package ipc is the local transport between gobid and its UI clients: a private unix socket,
// a single-instance lock, peer-UID checks and a versioned per-channel handshake.
// ponytail: unix only (macOS, Linux); the Windows transport (named pipes) comes with the Windows shell.
package ipc

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	SocketName = "gobid.sock"
	lockName   = "gobid.lock"

	// sun_path is 104 bytes on macOS and 108 on Linux; stay below both.
	maxSocketPath = 100
	fallbackBase  = "/tmp"

	staleProbeTimeout = 500 * time.Millisecond
)

var (
	ErrUnsafeDir      = errors.New("ipc: unsafe socket directory or file")
	ErrAlreadyRunning = errors.New("ipc: another gobid is already running")
)

// SocketDir returns the per-user socket directory under base. When the resulting socket path would
// exceed the unix socket path limit it falls back to a short deterministic directory.
func SocketDir(base string) string {
	dirName := fmt.Sprintf("gobi-%d", os.Geteuid())
	dir := filepath.Join(base, dirName)
	if len(filepath.Join(dir, SocketName)) > maxSocketPath {
		return filepath.Join(fallbackBase, dirName)
	}
	return dir
}

// EnsureDir creates dir with mode 0700 if missing and verifies it is a real directory
// (not a symlink) owned by the current user with exactly that mode.
func EnsureDir(dir string) error {
	err := os.Mkdir(dir, 0o700)
	switch {
	case err == nil:
		if err := os.Chmod(dir, 0o700); err != nil { // umask may have narrowed it
			return err
		}
	case !errors.Is(err, os.ErrExist):
		return err
	}

	dirStat, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !dirStat.IsDir() {
		return fmt.Errorf("%w: %s is not a directory", ErrUnsafeDir, dir)
	}
	if !ownedByCurrentUser(dirStat) {
		return fmt.Errorf("%w: %s is owned by another user", ErrUnsafeDir, dir)
	}
	if dirStat.Mode().Perm() != 0o700 {
		return fmt.Errorf("%w: %s has mode %o, want 700", ErrUnsafeDir, dir, dirStat.Mode().Perm())
	}
	return nil
}

func ownedByCurrentUser(fileStat os.FileInfo) bool {
	raw, ok := fileStat.Sys().(*syscall.Stat_t)
	return ok && int(raw.Uid) == os.Geteuid()
}

// Listen takes the single-instance lock in dir, clears a stale socket if one is left behind, and
// starts listening on dir/gobid.sock with mode 0600.
func Listen(dir string) (*Server, error) {
	if err := EnsureDir(dir); err != nil {
		return nil, err
	}
	lockFile, err := acquireLock(dir)
	if err != nil {
		return nil, err
	}

	socketPath := filepath.Join(dir, SocketName)
	if err := clearStaleSocket(socketPath); err != nil {
		lockFile.Close()
		return nil, err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		lockFile.Close()
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		listener.Close()
		lockFile.Close()
		return nil, err
	}
	return newServer(listener.(*net.UnixListener), lockFile, socketPath), nil
}

func acquireLock(dir string) (*os.File, error) {
	lockFile, err := os.OpenFile(filepath.Join(dir, lockName), os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lockFile.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lockFile.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrAlreadyRunning
		}
		return nil, err
	}
	return lockFile, nil
}

// clearStaleSocket removes socketPath only if it is a socket we own that nobody answers on.
func clearStaleSocket(socketPath string) error {
	socketStat, err := os.Lstat(socketPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if socketStat.Mode()&os.ModeSocket == 0 || !ownedByCurrentUser(socketStat) {
		return fmt.Errorf("%w: %s is not a socket owned by this user", ErrUnsafeDir, socketPath)
	}
	if probe, err := net.DialTimeout("unix", socketPath, staleProbeTimeout); err == nil {
		probe.Close()
		return ErrAlreadyRunning
	}
	return os.Remove(socketPath)
}

type closer struct {
	once sync.Once
	err  error
}

func (c *closer) do(closeFn func() error) error {
	c.once.Do(func() { c.err = closeFn() })
	return c.err
}
