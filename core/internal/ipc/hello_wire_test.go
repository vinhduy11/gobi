//go:build unix

package ipc

import (
	"bytes"
	"net"
	"strings"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

func TestHelloRoundTrips(t *testing.T) {
	hello := Hello{Protocol: 1, ClientVersion: "0.1", Channel: "lsp", WorkspaceRoot: "/work/héllo", Trusted: true, Language: "go"}
	decoded, err := DecodeHello(EncodeHello(hello))
	if err != nil || decoded != hello {
		t.Fatalf("got %+v (%v), want %+v", decoded, err, hello)
	}
}

// The Swift client has the same vector in its tests: if either side changes the layout, one of them fails.
func TestHelloGoldenBytes(t *testing.T) {
	got := EncodeHello(Hello{Protocol: 1, ClientVersion: "t", Channel: "control"})
	want := []byte{0x08, 0x01, 0x12, 0x01, 't', 0x1a, 0x07, 'c', 'o', 'n', 't', 'r', 'o', 'l', 0x28, 0x00}
	if !bytes.Equal(got, want) {
		t.Fatalf("hello bytes = % x, want % x", got, want)
	}
}

func TestReplyRoundTrips(t *testing.T) {
	for _, reply := range []Reply{{OK: true, Protocol: 1}, {OK: false, Protocol: 1, Error: "nope"}} {
		decoded, err := DecodeReply(EncodeReply(reply))
		if err != nil || decoded != reply {
			t.Fatalf("got %+v (%v), want %+v", decoded, err, reply)
		}
	}
}

func TestReplyGoldenBytes(t *testing.T) {
	got := EncodeReply(Reply{OK: true, Protocol: 1})
	want := []byte{0x08, 0x01, 0x10, 0x01}
	if !bytes.Equal(got, want) {
		t.Fatalf("reply bytes = % x, want % x", got, want)
	}
}

func TestDecodeHelloIgnoresUnknownFieldsAndRejectsGarbage(t *testing.T) {
	data := append(EncodeHello(Hello{Protocol: 1, Channel: "control"}), 0x78, 0x05) // field 15, varint 5: from a newer client
	if hello, err := DecodeHello(data); err != nil || hello.Channel != "control" {
		t.Fatalf("unknown field: %+v (%v)", hello, err)
	}
	if _, err := DecodeHello([]byte{0x12, 0x09, 'a'}); err == nil {
		t.Fatal("damaged hello accepted")
	}
}

func TestAJSONHandshakeIsRefusedWithAReadableReply(t *testing.T) {
	server, socketPath := startServer(t, 0)
	server.Handle("control", func(*Session) {})
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if err := rpc.NewWriter(conn).Write([]byte(`{"protocol":1,"channel":"control"}`)); err != nil {
		t.Fatal(err)
	}
	answer, err := rpc.NewReader(conn, 1<<16).Read()
	if err != nil {
		t.Fatal(err)
	}
	reply, err := DecodeReply(answer)
	if err != nil || reply.OK || !strings.Contains(reply.Error, "binary") {
		t.Fatalf("want a refusal that says the handshake is binary, got %+v (%v)", reply, err)
	}
}
