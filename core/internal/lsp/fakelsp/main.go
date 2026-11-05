// Command fakelsp is a scriptable stand-in for gopls used by the broker tests.
// Test clients drive it with fake/* requests (crash, slow, askConfiguration, ...).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"time"

	"gobi/core/internal/rpc"
)

type respError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *respError      `json:"error,omitempty"`
}

type openDoc struct {
	URI     string `json:"uri"`
	Version int    `json:"version"`
	Text    string `json:"text"`
}

type fakeServer struct {
	writer *rpc.Writer

	lock         sync.Mutex
	docs         map[string]openDoc
	cancelWaits  map[string]chan struct{}
	cancelCount  int
	outgoing     map[string]chan message
	outgoingNext int
}

func main() {
	server := &fakeServer{
		writer:      rpc.NewWriter(os.Stdout),
		docs:        map[string]openDoc{},
		cancelWaits: map[string]chan struct{}{},
		outgoing:    map[string]chan message{},
	}
	reader := rpc.NewReader(os.Stdin, 64<<20)
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
			server.deliverResponse(incoming)
		case incoming.Method != "" && len(incoming.ID) > 0:
			go server.handleRequest(incoming)
		case incoming.Method != "":
			server.handleNotification(incoming)
		}
	}
}

func (server *fakeServer) send(outgoing message) {
	outgoing.JSONRPC = "2.0"
	payload, _ := json.Marshal(outgoing)
	server.writer.Write(payload)
}

func (server *fakeServer) reply(request message, answer any) {
	encoded, _ := json.Marshal(answer)
	server.send(message{ID: request.ID, Result: encoded})
}

func (server *fakeServer) replyError(request message, code int, text string) {
	server.send(message{ID: request.ID, Error: &respError{Code: code, Message: text}})
}

func (server *fakeServer) deliverResponse(response message) {
	server.lock.Lock()
	waiter := server.outgoing[string(response.ID)]
	delete(server.outgoing, string(response.ID))
	server.lock.Unlock()
	if waiter != nil {
		waiter <- response
	}
}

// ask sends a server-to-client request and waits for the answer.
func (server *fakeServer) ask(method string, params any) (message, string) {
	server.lock.Lock()
	server.outgoingNext++
	idText := fmt.Sprintf(`"f%d"`, server.outgoingNext)
	waiter := make(chan message, 1)
	server.outgoing[idText] = waiter
	server.lock.Unlock()

	encoded, _ := json.Marshal(params)
	server.send(message{ID: json.RawMessage(idText), Method: method, Params: encoded})
	select {
	case response := <-waiter:
		return response, idText
	case <-time.After(10 * time.Second):
		return message{Error: &respError{Code: -1, Message: "client never answered"}}, idText
	}
}

func (server *fakeServer) handleNotification(notification message) {
	switch notification.Method {
	case "textDocument/didOpen":
		var params struct {
			TextDocument openDoc `json:"textDocument"`
		}
		json.Unmarshal(notification.Params, &params)
		server.lock.Lock()
		server.docs[params.TextDocument.URI] = params.TextDocument
		server.lock.Unlock()
	case "textDocument/didClose":
		var params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
		}
		json.Unmarshal(notification.Params, &params)
		server.lock.Lock()
		delete(server.docs, params.TextDocument.URI)
		server.lock.Unlock()
	case "$/cancelRequest":
		var params struct {
			ID json.RawMessage `json:"id"`
		}
		json.Unmarshal(notification.Params, &params)
		server.lock.Lock()
		server.cancelCount++
		if waiter := server.cancelWaits[string(params.ID)]; waiter != nil {
			close(waiter)
			delete(server.cancelWaits, string(params.ID))
		}
		server.lock.Unlock()
	case "exit":
		os.Exit(0)
	}
}

func (server *fakeServer) handleRequest(request message) {
	switch request.Method {
	case "initialize":
		server.reply(request, map[string]any{
			"capabilities": map[string]any{"textDocumentSync": map[string]any{"openClose": true, "change": 2}},
			"serverInfo":   map[string]any{"name": "fakelsp"},
		})
	case "shutdown":
		server.reply(request, nil)
	case "fake/pid":
		server.reply(request, map[string]any{"pid": os.Getpid()})
	case "fake/env":
		server.reply(request, map[string]any{"gotoolchain": os.Getenv("GOTOOLCHAIN")})
	case "textDocument/hover":
		var params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
			DelayMS int `json:"delayMs"`
		}
		json.Unmarshal(request.Params, &params)
		time.Sleep(time.Duration(params.DelayMS) * time.Millisecond)
		server.reply(request, map[string]any{"contents": "hover:" + params.TextDocument.URI, "seenID": string(request.ID)})
	case "fake/slow":
		waiter := make(chan struct{})
		server.lock.Lock()
		server.cancelWaits[string(request.ID)] = waiter
		server.lock.Unlock()
		select {
		case <-waiter:
			server.replyError(request, -32800, "cancelled")
		case <-time.After(10 * time.Second):
			server.reply(request, "timeout")
		}
	case "fake/askConfiguration":
		answer, _ := server.ask("workspace/configuration", map[string]any{
			"items": []map[string]any{{"section": "gopls"}, {"section": "editor"}},
		})
		server.send(message{ID: request.ID, Result: answer.Result, Error: answer.Error})
	case "fake/askApplyEdit":
		answer, askedID := server.ask("workspace/applyEdit", map[string]any{"edit": map[string]any{}})
		server.reply(request, map[string]any{"relayed": answer.Result, "askedID": askedID})
	case "fake/notify":
		encoded, _ := json.Marshal(map[string]any{"type": 3, "message": "hi"})
		server.send(message{Method: "window/showMessage", Params: encoded})
		server.reply(request, nil)
	case "fake/openDocs":
		server.lock.Lock()
		listed := make([]openDoc, 0, len(server.docs))
		for _, doc := range server.docs {
			listed = append(listed, doc)
		}
		server.lock.Unlock()
		sort.Slice(listed, func(i, j int) bool { return listed[i].URI < listed[j].URI })
		server.reply(request, listed)
	case "fake/cancelCount":
		server.lock.Lock()
		count := server.cancelCount
		server.lock.Unlock()
		server.reply(request, map[string]any{"count": count})
	case "fake/crash":
		os.Exit(2)
	case "fake/malformed":
		os.Stdout.WriteString("Content-Length: abc\r\n\r\n")
		os.Exit(0)
	default:
		server.replyError(request, -32601, "method not found: "+request.Method)
	}
}
