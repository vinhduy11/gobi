package lsp

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

var fakeBinary string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "fakelsp")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fakeBinary = filepath.Join(dir, "fakelsp")
	if output, err := exec.Command("go", "build", "-o", fakeBinary, "./fakelsp").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build fakelsp: %v\n%s", err, output)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

const waitLimit = 5 * time.Second

func newTestBroker(t *testing.T, command ...string) *Broker {
	t.Helper()
	if len(command) == 0 {
		command = []string{fakeBinary}
	}
	broker := NewBroker(Config{
		Root:         "/work/hello",
		Command:      command,
		Logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		RestartDelay: 10 * time.Millisecond,
	})
	t.Cleanup(broker.Close)
	return broker
}

// testClient speaks LSP to a Broker over an in-memory pipe.
type testClient struct {
	t              *testing.T
	pipe           net.Conn
	writer         *rpc.Writer
	nextID         int
	lock           sync.Mutex
	waiting        map[string]chan message
	notifications  chan message
	serverRequests chan message
}

func newTestClient(t *testing.T, broker *Broker) *testClient {
	t.Helper()
	return newTestClientVia(t, broker.Attach)
}

// newTestClientVia connects a client through any function that serves an LSP connection.
func newTestClientVia(t *testing.T, serve func(*rpc.Reader, *rpc.Writer) error) *testClient {
	t.Helper()
	serverEnd, clientEnd := net.Pipe()
	go func() {
		serve(rpc.NewReader(serverEnd, 64<<20), rpc.NewWriter(serverEnd))
		serverEnd.Close()
	}()
	client := &testClient{
		t:              t,
		pipe:           clientEnd,
		writer:         rpc.NewWriter(clientEnd),
		nextID:         1,
		waiting:        map[string]chan message{},
		notifications:  make(chan message, 64),
		serverRequests: make(chan message, 64),
	}
	go client.readLoop(rpc.NewReader(clientEnd, 64<<20))
	t.Cleanup(func() { clientEnd.Close() })
	return client
}

func (client *testClient) readLoop(reader *rpc.Reader) {
	for {
		payload, err := reader.Read()
		if err != nil {
			return
		}
		var incoming message
		if json.Unmarshal(payload, &incoming) != nil {
			continue
		}
		switch {
		case incoming.Method == "" && len(incoming.ID) > 0:
			client.lock.Lock()
			waiter := client.waiting[string(incoming.ID)]
			delete(client.waiting, string(incoming.ID))
			client.lock.Unlock()
			if waiter != nil {
				waiter <- incoming
			}
		case len(incoming.ID) > 0:
			client.serverRequests <- incoming
		default:
			client.notifications <- incoming
		}
	}
}

// start sends a request and returns its id and the channel the response will arrive on.
func (client *testClient) start(method string, params any) (int, <-chan message) {
	client.t.Helper()
	client.lock.Lock()
	client.nextID++
	id := client.nextID
	waiter := make(chan message, 1)
	client.waiting[strconv.Itoa(id)] = waiter
	client.lock.Unlock()

	encoded, _ := json.Marshal(params)
	request, _ := json.Marshal(message{JSONRPC: "2.0", ID: json.RawMessage(strconv.Itoa(id)), Method: method, Params: encoded})
	if err := client.writer.Write(request); err != nil {
		client.t.Fatalf("write %s: %v", method, err)
	}
	return id, waiter
}

func (client *testClient) await(waiter <-chan message) message {
	client.t.Helper()
	select {
	case response := <-waiter:
		return response
	case <-time.After(waitLimit):
		client.t.Fatal("timed out waiting for a response")
		return message{}
	}
}

func (client *testClient) call(method string, params any) message {
	client.t.Helper()
	_, waiter := client.start(method, params)
	return client.await(waiter)
}

func (client *testClient) notify(method string, params any) {
	client.t.Helper()
	encoded, _ := json.Marshal(params)
	notification, _ := json.Marshal(message{JSONRPC: "2.0", Method: method, Params: encoded})
	if err := client.writer.Write(notification); err != nil {
		client.t.Fatalf("write %s: %v", method, err)
	}
}

func (client *testClient) respond(id json.RawMessage, answer any) {
	client.t.Helper()
	encoded, _ := json.Marshal(answer)
	response, _ := json.Marshal(message{JSONRPC: "2.0", ID: id, Result: encoded})
	if err := client.writer.Write(response); err != nil {
		client.t.Fatalf("write response: %v", err)
	}
}

func (client *testClient) initialize() message {
	client.t.Helper()
	response := client.call("initialize", map[string]any{"processId": nil, "rootUri": "file:///elsewhere", "capabilities": map[string]any{}})
	client.notify("initialized", map[string]any{})
	return response
}

func (client *testClient) expectNotification(method string) message {
	client.t.Helper()
	deadline := time.After(waitLimit)
	for {
		select {
		case notification := <-client.notifications:
			if notification.Method == method {
				return notification
			}
		case <-deadline:
			client.t.Fatalf("no %s notification", method)
		}
	}
}

func (client *testClient) openDoc(uri, text string) {
	client.t.Helper()
	client.notify("textDocument/didOpen", map[string]any{
		"textDocument": map[string]any{"uri": uri, "languageId": "go", "version": 1, "text": text},
	})
}

func decodeResult[T any](t *testing.T, response message) T {
	t.Helper()
	if response.Error != nil {
		t.Fatalf("unexpected error response: %+v", response.Error)
	}
	var decoded T
	if err := json.Unmarshal(response.Result, &decoded); err != nil {
		t.Fatalf("decode %s: %v", response.Result, err)
	}
	return decoded
}

type pidResult struct {
	PID int `json:"pid"`
}

type openDocResult struct {
	URI     string `json:"uri"`
	Version int    `json:"version"`
	Text    string `json:"text"`
}
