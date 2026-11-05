package rpc

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"testing/iotest"
)

func frame(payload string) string {
	return fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(payload), payload)
}

func TestReadSingleMessage(t *testing.T) {
	r := NewReader(strings.NewReader(frame(`{"jsonrpc":"2.0"}`)), 1<<20)
	got, err := r.Read()
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"jsonrpc":"2.0"}` {
		t.Fatalf("got %q", got)
	}
}

func TestReadBackToBackMessages(t *testing.T) {
	r := NewReader(strings.NewReader(frame("one")+frame("two")), 1<<20)
	for _, want := range []string{"one", "two"} {
		got, err := r.Read()
		if err != nil || string(got) != want {
			t.Fatalf("got %q, %v; want %q", got, err, want)
		}
	}
	if _, err := r.Read(); err != io.EOF {
		t.Fatalf("want io.EOF at clean end, got %v", err)
	}
}

func TestReadByteByByte(t *testing.T) {
	r := NewReader(iotest.OneByteReader(strings.NewReader(frame("hello"))), 1<<20)
	got, err := r.Read()
	if err != nil || string(got) != "hello" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestReadAcceptsContentType(t *testing.T) {
	in := "Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\nhi"
	got, err := NewReader(strings.NewReader(in), 1<<20).Read()
	if err != nil || string(got) != "hi" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestReadRejectsBadHeaders(t *testing.T) {
	tests := map[string]string{
		"missing length":     "Content-Type: x\r\n\r\nhi",
		"duplicate length":   "Content-Length: 2\r\nContent-Length: 2\r\n\r\nhi",
		"duplicate type":     "Content-Length: 2\r\nContent-Type: a\r\nContent-Type: b\r\n\r\nhi",
		"non numeric":        "Content-Length: 12a\r\n\r\nhi",
		"negative":           "Content-Length: -1\r\n\r\n",
		"plus sign":          "Content-Length: +2\r\n\r\nhi",
		"empty value":        "Content-Length: \r\n\r\n",
		"overflow":           "Content-Length: 99999999999999999999\r\n\r\n",
		"bare LF":            "Content-Length: 2\n\nhi",
		"line without colon": "Content-Length 2\r\n\r\nhi",
		"unknown header":     "Content-Length: 2\r\nX-Evil: 1\r\n\r\nhi",
	}
	for name, in := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := NewReader(strings.NewReader(in), 1<<20).Read()
			if !errors.Is(err, ErrMalformedHeader) {
				t.Fatalf("want ErrMalformedHeader, got %v", err)
			}
		})
	}
}

func TestReadRejectsOversize(t *testing.T) {
	_, err := NewReader(strings.NewReader("Content-Length: 11\r\n\r\n"), 10).Read()
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("want ErrTooLarge, got %v", err)
	}
}

func TestReadAllowsExactlyMax(t *testing.T) {
	got, err := NewReader(strings.NewReader(frame("0123456789")), 10).Read()
	if err != nil || len(got) != 10 {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestReadTruncated(t *testing.T) {
	for name, in := range map[string]string{
		"mid header": "Content-Length: 5\r\n",
		"mid body":   "Content-Length: 5\r\n\r\nab",
	} {
		t.Run(name, func(t *testing.T) {
			_, err := NewReader(strings.NewReader(in), 1<<20).Read()
			if !errors.Is(err, io.ErrUnexpectedEOF) {
				t.Fatalf("want io.ErrUnexpectedEOF, got %v", err)
			}
		})
	}
}

func TestReadEmptyBody(t *testing.T) {
	got, err := NewReader(strings.NewReader(frame("")), 1<<20).Read()
	if err != nil || len(got) != 0 {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestWriteFramesPayload(t *testing.T) {
	var wire bytes.Buffer
	if err := NewWriter(&wire).Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	if wire.String() != frame("hello") {
		t.Fatalf("got %q", wire.String())
	}
}

func TestWriteIsAtomicUnderConcurrency(t *testing.T) {
	var wire bytes.Buffer
	w := NewWriter(&wire)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = w.Write([]byte(strings.Repeat("x", 100)))
		}()
	}
	wg.Wait()

	r := NewReader(&wire, 1<<20)
	for i := 0; i < 50; i++ {
		got, err := r.Read()
		if err != nil || len(got) != 100 {
			t.Fatalf("message %d: len %d, %v", i, len(got), err)
		}
	}
}

func TestWriteReadRoundTrip(t *testing.T) {
	var wire bytes.Buffer
	payload := []byte(`{"id":1,"method":"initialize"}`)
	if err := NewWriter(&wire).Write(payload); err != nil {
		t.Fatal(err)
	}
	got, err := NewReader(&wire, 1<<20).Read()
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("got %q, %v", got, err)
	}
}

func FuzzRead(f *testing.F) {
	f.Add([]byte(frame("hello")))
	f.Add([]byte("Content-Length: 5\r\n\r\nab"))
	f.Add([]byte("Content-Length: 99999999999\r\n\r\n"))
	f.Add([]byte("\r\n\r\n"))
	f.Fuzz(func(t *testing.T, in []byte) {
		r := NewReader(bytes.NewReader(in), 1<<16)
		for i := 0; i < 8; i++ {
			got, err := r.Read()
			if err != nil {
				return
			}
			if len(got) > 1<<16 {
				t.Fatalf("payload %d exceeds max", len(got))
			}
		}
	})
}

func BenchmarkReadWrite(b *testing.B) {
	payload := bytes.Repeat([]byte("x"), 4096)
	var wire bytes.Buffer
	w := NewWriter(&wire)
	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	for i := 0; i < b.N; i++ {
		wire.Reset()
		_ = w.Write(payload)
		_, _ = NewReader(&wire, 1<<20).Read()
	}
}
