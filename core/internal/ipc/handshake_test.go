//go:build unix

package ipc

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

func startServer(t *testing.T, handshakeTimeout time.Duration) (*Server, string) {
	t.Helper()
	dir := filepath.Join(newTestDir(t), "d")
	server, err := Listen(dir)
	if err != nil {
		t.Fatal(err)
	}
	if handshakeTimeout > 0 {
		server.handshakeTimeout = handshakeTimeout
	}
	t.Cleanup(func() { server.Close() })
	go server.Serve()
	return server, filepath.Join(dir, SocketName)
}

func TestHandshakeAcceptedAndRoutedToChannelHandler(t *testing.T) {
	server, socketPath := startServer(t, 0)
	seen := make(chan Hello, 1)
	server.Handle("lsp", func(session *Session) {
		seen <- session.Hello
		payload, err := session.Reader.Read()
		if err == nil {
			session.Writer.Write(append([]byte("echo:"), payload...))
		}
	})

	client, err := Dial(socketPath, Hello{ClientVersion: "test", Channel: "lsp", WorkspaceRoot: "/work/hello", Trusted: true, Language: "json"})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	if err := client.Writer.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	reply, err := client.Reader.Read()
	if err != nil || string(reply) != "echo:ping" {
		t.Fatalf("reply %q, %v", reply, err)
	}
	select {
	case hello := <-seen:
		if hello.Channel != "lsp" || hello.WorkspaceRoot != "/work/hello" || hello.ClientVersion != "test" || !hello.Trusted || hello.Language != "json" {
			t.Fatalf("handler saw %+v", hello)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("handler not called")
	}
}

func TestHandshakeRejections(t *testing.T) {
	server, socketPath := startServer(t, 0)
	server.Handle("control", func(*Session) {})

	tests := map[string]struct {
		hello   Hello
		message string
	}{
		"wrong protocol":        {Hello{Protocol: ProtocolVersion + 1, Channel: "control"}, "protocol"},
		"unknown channel":       {Hello{Channel: "bogus"}, "channel"},
		"channel not served":    {Hello{Channel: "dap"}, "not available"},
		"lsp needs a workspace": {Hello{Channel: "lsp"}, "workspace"},
	}
	server.Handle("lsp", func(*Session) {})
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			if test.hello.Protocol == 0 {
				test.hello.Protocol = ProtocolVersion
			}
			_, err := Dial(socketPath, test.hello)
			if err == nil || !strings.Contains(err.Error(), test.message) {
				t.Fatalf("want error containing %q, got %v", test.message, err)
			}
		})
	}
}

func TestAdmitHookCanRefuseAHandshake(t *testing.T) {
	server, socketPath := startServer(t, 0)
	server.Handle("lsp", func(*Session) {})
	server.SetAdmit(func(hello Hello) string {
		if hello.Language == "cobol" {
			return `language "cobol" is not supported`
		}
		return ""
	})

	if _, err := Dial(socketPath, Hello{Channel: "lsp", WorkspaceRoot: "/w", Language: "cobol"}); err == nil || !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("want the hook's reason, got %v", err)
	}
	session, err := Dial(socketPath, Hello{Channel: "lsp", WorkspaceRoot: "/w", Language: "json"})
	if err != nil {
		t.Fatalf("an admitted language must connect: %v", err)
	}
	session.Close()
}

func TestHandshakeTimesOutOnSilentClient(t *testing.T) {
	_, socketPath := startServer(t, 100*time.Millisecond)

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := rpc.NewReader(conn, 1<<16).Read(); err == nil {
		t.Fatal("server must close a connection that never sends a handshake")
	}
}
