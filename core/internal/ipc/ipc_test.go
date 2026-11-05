//go:build unix

package ipc

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newTestDir returns a short private directory: macOS limits unix socket paths to about 104 bytes,
// which t.TempDir() can exceed.
func newTestDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "gb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestEnsureDirCreatesPrivateDir(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "gobi-test")
	if err := EnsureDir(dir); err != nil {
		t.Fatal(err)
	}
	dirStat, err := os.Lstat(dir)
	if err != nil || !dirStat.IsDir() || dirStat.Mode().Perm() != 0o700 {
		t.Fatalf("stat %v, err %v", dirStat, err)
	}
	if err := EnsureDir(dir); err != nil {
		t.Fatalf("second call must be idempotent: %v", err)
	}
}

func TestEnsureDirRejectsUnsafeDirs(t *testing.T) {
	base := newTestDir(t)

	loose := filepath.Join(base, "loose")
	if err := os.Mkdir(loose, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(loose, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(loose); !errors.Is(err, ErrUnsafeDir) {
		t.Fatalf("loose permissions: got %v", err)
	}

	target := filepath.Join(base, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(link); !errors.Is(err, ErrUnsafeDir) {
		t.Fatalf("symlink: got %v", err)
	}

	plainFile := filepath.Join(base, "file")
	if err := os.WriteFile(plainFile, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := EnsureDir(plainFile); !errors.Is(err, ErrUnsafeDir) {
		t.Fatalf("regular file: got %v", err)
	}
}

func TestSocketDirKeepsShortPathsAndFallsBackForLongOnes(t *testing.T) {
	if short := SocketDir("/var/run"); !strings.HasPrefix(short, "/var/run/gobi-") {
		t.Fatalf("short base: %q", short)
	}

	long := SocketDir("/" + strings.Repeat("a", 200))
	if socketPath := filepath.Join(long, SocketName); len(socketPath) > maxSocketPath {
		t.Fatalf("fallback path still too long (%d): %s", len(socketPath), socketPath)
	}
	if !strings.HasPrefix(long, fallbackBase+"/gobi-") {
		t.Fatalf("fallback dir %q", long)
	}
}

func TestListenCreatesSocketWithOwnerOnlyPermissions(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "d")
	server, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	socketStat, err := os.Lstat(filepath.Join(dir, SocketName))
	if err != nil || socketStat.Mode()&os.ModeSocket == 0 || socketStat.Mode().Perm() != 0o600 {
		t.Fatalf("socket stat %v, err %v", socketStat, err)
	}
}

func TestListenRejectsSecondInstance(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "d")
	first, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(dir); !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("want ErrAlreadyRunning, got %v", err)
	}
	first.Close()

	again, err := Listen(dir)
	if err != nil {
		t.Fatalf("after Close the dir must be reusable: %v", err)
	}
	again.Close()
}

func TestListenRecoversStaleSocket(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "d")
	if err := EnsureDir(dir); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(dir, SocketName)
	stale, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	stale.Close() // leaves the socket file behind with nobody listening

	server, err := Listen(dir)
	if err != nil {
		t.Fatalf("stale socket must be recovered: %v", err)
	}
	server.Close()
}

func TestListenRefusesLiveForeignSocket(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "d")
	if err := EnsureDir(dir); err != nil {
		t.Fatal(err)
	}
	live, err := net.Listen("unix", filepath.Join(dir, SocketName))
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()

	if _, err := Listen(dir); !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("want ErrAlreadyRunning, got %v", err)
	}
	if _, err := os.Lstat(filepath.Join(dir, SocketName)); err != nil {
		t.Fatalf("live socket must not be removed: %v", err)
	}
}

func TestListenRefusesNonSocketFiles(t *testing.T) {
	for name, create := range map[string]func(path string) error{
		"regular file": func(path string) error { return os.WriteFile(path, []byte("keep"), 0o600) },
		"symlink":      func(path string) error { return os.Symlink("/etc/hosts", path) },
	} {
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(newTestDir(t), "d")
			if err := EnsureDir(dir); err != nil {
				t.Fatal(err)
			}
			socketPath := filepath.Join(dir, SocketName)
			if err := create(socketPath); err != nil {
				t.Fatal(err)
			}
			if _, err := Listen(dir); !errors.Is(err, ErrUnsafeDir) {
				t.Fatalf("want ErrUnsafeDir, got %v", err)
			}
			if _, err := os.Lstat(socketPath); err != nil {
				t.Fatalf("foreign file must be left alone: %v", err)
			}
		})
	}
}

func TestPeerUIDMatchesCurrentUser(t *testing.T) {
	dir := filepath.Join(newTestDir(t), "d")
	server, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, _ := server.listener.Accept()
		accepted <- conn
	}()
	client, err := net.Dial("unix", filepath.Join(dir, SocketName))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	serverSide := <-accepted
	defer serverSide.Close()
	uid, err := peerUID(serverSide.(*net.UnixConn))
	if err != nil || int(uid) != os.Geteuid() {
		t.Fatalf("peerUID = %d, %v; want %d", uid, err, os.Geteuid())
	}
}
