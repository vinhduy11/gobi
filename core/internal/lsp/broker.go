package lsp

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"gobi/core/internal/rpc"
)

const (
	codeServerRestarted   = -32099
	codeServerUnavailable = -32098
	codeInternalError     = -32603

	maxServerMessage  = 256 << 20
	initializeTimeout = 30 * time.Second
	stopGracePeriod   = time.Second
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

// Config describes the language server a Broker supervises.
type Config struct {
	Root         string // workspace root; the server runs here
	Command      []string
	Env          []string // environment of the server process; nil inherits gobid's
	Logger       *slog.Logger
	RestartDelay time.Duration // base delay between restart attempts
	MaxRestarts  int           // consecutive failed restart attempts before giving up
}

type attachedClient struct {
	id     int
	writer *rpc.Writer
}

type serverProcess struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	writer  *rpc.Writer
}

func (process *serverProcess) kill() { process.command.Process.Kill() }

// pendingRequest is a request sent to the server whose response is still awaited.
type pendingRequest struct {
	owner      *attachedClient // nil for requests the broker made itself
	originalID json.RawMessage
	process    *serverProcess
	internal   chan message // set for broker-made requests
}

// outgoingRequest is a server-to-client request waiting for the client's answer.
type outgoingRequest struct {
	serverID json.RawMessage
	process  *serverProcess
	owner    *attachedClient
}

// Broker owns one language server for a workspace and multiplexes any number of clients onto it.
// It performs initialize itself, translates request ids both ways, answers the server's
// housekeeping requests, forwards the rest, and restarts the server replaying open documents.
type Broker struct {
	config   Config
	bootLock sync.Mutex // serialises server start-up and restart

	lock           sync.Mutex // guards everything below
	clients        map[int]*attachedClient
	nextClientID   int
	docs           *docStore
	pending        map[int64]*pendingRequest
	nextServerID   int64
	outgoing       map[string]*outgoingRequest
	nextOutgoingID int64
	epoch          int
	server         *serverProcess
	restarting     bool
	initParams     json.RawMessage
	initResult     json.RawMessage
	closed         bool
}

func NewBroker(config Config) *Broker {
	if config.Logger == nil {
		config.Logger = slog.Default()
	}
	if config.RestartDelay == 0 {
		config.RestartDelay = 200 * time.Millisecond
	}
	if config.MaxRestarts == 0 {
		config.MaxRestarts = 5
	}
	config.Logger = config.Logger.With("component", "lsp.broker", "root", config.Root)
	return &Broker{
		config:   config,
		clients:  map[int]*attachedClient{},
		docs:     newDocStore(),
		pending:  map[int64]*pendingRequest{},
		outgoing: map[string]*outgoingRequest{},
	}
}

// Attach serves one client until it disconnects. Reads and writes use the LSP base protocol.
func (b *Broker) Attach(reader *rpc.Reader, writer *rpc.Writer) error {
	client, err := b.addClient(writer)
	if err != nil {
		return err
	}
	defer b.removeClient(client)
	for {
		payload, err := reader.Read()
		if err != nil {
			return nil
		}
		b.handleClientMessage(client, payload)
	}
}

// Close stops the language server. Attached clients are left to disconnect on their own.
func (b *Broker) Close() {
	b.lock.Lock()
	if b.closed {
		b.lock.Unlock()
		return
	}
	b.closed = true
	process := b.server
	b.server = nil
	b.lock.Unlock()

	if process == nil {
		return
	}
	process.writer.Write(encodeNotification("exit", nil))
	process.stdin.Close()
	time.AfterFunc(stopGracePeriod, process.kill)
}

func (b *Broker) addClient(writer *rpc.Writer) (*attachedClient, error) {
	b.lock.Lock()
	defer b.lock.Unlock()
	if b.closed {
		return nil, errors.New("lsp: broker closed")
	}
	b.nextClientID++
	client := &attachedClient{id: b.nextClientID, writer: writer}
	b.clients[client.id] = client
	return client, nil
}

// removeClient cancels the client's requests, answers server requests it still owed, and closes
// documents nobody else has open.
func (b *Broker) removeClient(client *attachedClient) {
	b.lock.Lock()
	delete(b.clients, client.id)
	process := b.server

	var cancelledIDs []int64
	for serverID, request := range b.pending {
		if request.owner == client {
			cancelledIDs = append(cancelledIDs, serverID)
			delete(b.pending, serverID)
		}
	}
	var orphaned []*outgoingRequest
	for outgoingID, request := range b.outgoing {
		if request.owner == client {
			orphaned = append(orphaned, request)
			delete(b.outgoing, outgoingID)
		}
	}
	closedURIs := b.docs.dropOwner(client.id)

	if process != nil {
		for _, serverID := range cancelledIDs {
			process.writer.Write(encodeNotification("$/cancelRequest", map[string]any{"id": serverID}))
		}
		for _, uri := range closedURIs {
			process.writer.Write(encodeNotification("textDocument/didClose", map[string]any{"textDocument": map[string]string{"uri": uri}}))
		}
	}
	b.lock.Unlock()

	for _, request := range orphaned {
		request.process.writer.Write(encodeError(request.serverID, codeInternalError, "client disconnected"))
	}
}

// ---- client to server ----

// handleClientMessage reads only id and method; params are decoded for the few methods that need them.
func (b *Broker) handleClientMessage(client *attachedClient, payload []byte) {
	id, method, ok := peekHeader(payload)
	if !ok {
		b.config.Logger.Warn("dropping malformed client message")
		return
	}
	hasID := len(id) > 0
	switch {
	case method == "" && hasID:
		b.routeClientResponse(id, payload)
	case method == "initialize" && hasID:
		b.handleInitialize(client, id, paramsOf(payload))
	case method == "shutdown" && hasID:
		client.writer.Write(encodeResult(id, json.RawMessage("null")))
	case method == "initialized" || method == "exit":
		// the broker owns the server lifecycle
	case method == "$/cancelRequest":
		b.forwardCancel(client, paramsOf(payload))
	case method == "textDocument/didOpen" || method == "textDocument/didChange" || method == "textDocument/didClose":
		b.trackDocument(client, method, paramsOf(payload), payload)
	case hasID:
		b.forwardRequest(client, id, payload)
	default:
		b.forwardNotification(payload)
	}
}

func paramsOf(payload []byte) json.RawMessage {
	var envelope struct {
		Params json.RawMessage `json:"params"`
	}
	json.Unmarshal(payload, &envelope)
	return envelope.Params
}

func (b *Broker) handleInitialize(client *attachedClient, id, clientParams json.RawMessage) {
	b.bootLock.Lock()
	defer b.bootLock.Unlock()

	b.lock.Lock()
	cached := b.initResult
	serving := b.server != nil || b.restarting
	b.lock.Unlock()
	if cached != nil && serving {
		client.writer.Write(encodeResult(id, cached))
		return
	}

	params := b.buildInitializeParams(clientParams)
	result, err := b.boot(params)
	if err != nil {
		b.config.Logger.Error("language server failed to start", "error", err)
		client.writer.Write(encodeError(id, codeServerUnavailable, "language server unavailable: "+err.Error()))
		return
	}
	b.lock.Lock()
	b.initParams, b.initResult = params, result
	b.lock.Unlock()
	client.writer.Write(encodeResult(id, result))
}

// buildInitializeParams keeps the client's capabilities but pins the process id and workspace to the broker's.
func (b *Broker) buildInitializeParams(clientParams json.RawMessage) json.RawMessage {
	fields := map[string]json.RawMessage{}
	json.Unmarshal(clientParams, &fields)

	rootURI := (&url.URL{Scheme: "file", Path: b.config.Root}).String()
	fields["processId"] = json.RawMessage(strconv.Itoa(os.Getpid()))
	fields["rootUri"], _ = json.Marshal(rootURI)
	delete(fields, "rootPath")
	fields["workspaceFolders"], _ = json.Marshal([]map[string]string{{"uri": rootURI, "name": filepath.Base(b.config.Root)}})
	if _, ok := fields["capabilities"]; !ok {
		fields["capabilities"] = json.RawMessage("{}")
	}
	fields["initializationOptions"] = withSemanticTokens(fields["initializationOptions"])
	encoded, _ := json.Marshal(fields)
	return encoded
}

// withSemanticTokens switches on gopls' semantic tokens, which it only sends when asked, keeping what the client set. A client that
// sets the option itself keeps its choice.
func withSemanticTokens(raw json.RawMessage) json.RawMessage {
	options := map[string]any{}
	json.Unmarshal(raw, &options)
	if _, set := options["ui.semanticTokens"]; !set {
		options["ui.semanticTokens"] = true
	}
	encoded, _ := json.Marshal(options)
	return encoded
}

func (b *Broker) forwardRequest(client *attachedClient, id json.RawMessage, payload []byte) {
	b.lock.Lock()
	process := b.server
	if process == nil {
		restarting := b.restarting
		b.lock.Unlock()
		code, text := codeServerUnavailable, "language server unavailable"
		if restarting {
			code, text = codeServerRestarted, "language server restarting"
		}
		client.writer.Write(encodeError(id, code, text))
		return
	}
	b.nextServerID++
	serverID := b.nextServerID
	b.pending[serverID] = &pendingRequest{owner: client, originalID: id, process: process}
	b.lock.Unlock()

	rewritten, err := rewriteID(payload, numberID(serverID))
	if err == nil {
		err = process.writer.Write(rewritten)
	}
	if err != nil {
		b.lock.Lock()
		_, stillPending := b.pending[serverID]
		delete(b.pending, serverID)
		b.lock.Unlock()
		if stillPending {
			client.writer.Write(encodeError(id, codeServerRestarted, "language server restarting"))
		}
	}
}

func (b *Broker) forwardNotification(payload []byte) {
	b.lock.Lock()
	process := b.server
	b.lock.Unlock()
	if process != nil {
		process.writer.Write(payload)
	}
}

func (b *Broker) forwardCancel(client *attachedClient, rawParams json.RawMessage) {
	var params struct {
		ID json.RawMessage `json:"id"`
	}
	if json.Unmarshal(rawParams, &params) != nil {
		return
	}
	b.lock.Lock()
	defer b.lock.Unlock()
	if b.server == nil {
		return
	}
	for serverID, request := range b.pending {
		if request.owner == client && string(request.originalID) == string(params.ID) {
			b.server.writer.Write(encodeNotification("$/cancelRequest", map[string]any{"id": serverID}))
			return
		}
	}
}

func (b *Broker) routeClientResponse(id json.RawMessage, payload []byte) {
	b.lock.Lock()
	request := b.outgoing[string(id)]
	delete(b.outgoing, string(id))
	b.lock.Unlock()
	if request == nil {
		return
	}
	if rewritten, err := rewriteID(payload, request.serverID); err == nil {
		request.process.writer.Write(rewritten)
	}
}

// trackDocument records open documents for replay and decides whether the notification reaches the
// server (a document opened by several clients is opened in the server once).
func (b *Broker) trackDocument(client *attachedClient, method string, rawParams json.RawMessage, payload []byte) {
	var params struct {
		TextDocument struct {
			URI        string `json:"uri"`
			LanguageID string `json:"languageId"`
			Version    int    `json:"version"`
			Text       string `json:"text"`
		} `json:"textDocument"`
		ContentChanges []contentChange `json:"contentChanges"`
	}
	if json.Unmarshal(rawParams, &params) != nil {
		return
	}
	document := params.TextDocument

	b.lock.Lock()
	defer b.lock.Unlock()
	forward := false
	switch method {
	case "textDocument/didOpen":
		forward = b.docs.open(document.URI, document.LanguageID, document.Version, document.Text, client.id)
	case "textDocument/didChange":
		forward = b.docs.change(document.URI, document.Version, params.ContentChanges)
	case "textDocument/didClose":
		forward = b.docs.close(document.URI, client.id)
	}
	if forward && b.server != nil {
		b.server.writer.Write(payload)
	}
}

// ---- server to client ----

func (b *Broker) handleServerMessage(process *serverProcess, payload []byte) {
	id, method, ok := peekHeader(payload)
	if !ok {
		b.config.Logger.Warn("dropping malformed server message")
		return
	}
	hasID := len(id) > 0
	switch {
	case method == "" && hasID:
		b.routeServerResponse(id, payload)
	case hasID:
		b.handleServerRequest(process, id, method, paramsOf(payload), payload)
	case method != "":
		b.broadcast(payload)
	}
}

func (b *Broker) routeServerResponse(id json.RawMessage, payload []byte) {
	serverID, err := strconv.ParseInt(string(id), 10, 64)
	if err != nil {
		return
	}
	b.lock.Lock()
	request := b.pending[serverID]
	delete(b.pending, serverID)
	b.lock.Unlock()
	if request == nil {
		return
	}
	if request.internal != nil {
		var response message
		json.Unmarshal(payload, &response)
		request.internal <- response
		return
	}
	if rewritten, err := rewriteID(payload, request.originalID); err == nil {
		request.owner.writer.Write(rewritten)
	}
}

func (b *Broker) handleServerRequest(process *serverProcess, id json.RawMessage, method string, rawParams json.RawMessage, payload []byte) {
	switch method {
	case "workspace/configuration":
		var params struct {
			Items []json.RawMessage `json:"items"`
		}
		json.Unmarshal(rawParams, &params)
		answers := make([]json.RawMessage, len(params.Items))
		for index := range answers {
			answers[index] = json.RawMessage("null")
		}
		encoded, _ := json.Marshal(answers)
		process.writer.Write(encodeResult(id, encoded))
	case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
		process.writer.Write(encodeResult(id, json.RawMessage("null")))
	default:
		b.forwardServerRequest(process, id, payload)
	}
}

// forwardServerRequest sends a server request to the earliest attached client under a broker-owned id.
func (b *Broker) forwardServerRequest(process *serverProcess, id json.RawMessage, payload []byte) {
	b.lock.Lock()
	var target *attachedClient
	for _, candidate := range b.clients {
		if target == nil || candidate.id < target.id {
			target = candidate
		}
	}
	if target == nil {
		b.lock.Unlock()
		process.writer.Write(encodeError(id, codeInternalError, "no client attached"))
		return
	}
	b.nextOutgoingID++
	outgoingID := json.RawMessage(strconv.Quote("gobi:" + strconv.FormatInt(b.nextOutgoingID, 10)))
	b.outgoing[string(outgoingID)] = &outgoingRequest{serverID: id, process: process, owner: target}
	b.lock.Unlock()

	if rewritten, err := rewriteID(payload, outgoingID); err == nil {
		target.writer.Write(rewritten)
	}
}

func (b *Broker) broadcast(payload []byte) {
	b.lock.Lock()
	recipients := make([]*attachedClient, 0, len(b.clients))
	for _, client := range b.clients {
		recipients = append(recipients, client)
	}
	b.lock.Unlock()
	for _, client := range recipients {
		client.writer.Write(payload)
	}
}

// ---- server lifecycle ----

// boot starts a server process, runs initialize, replays open documents and makes it current.
// Callers hold bootLock.
func (b *Broker) boot(initParams json.RawMessage) (json.RawMessage, error) {
	process, err := b.spawn()
	if err != nil {
		return nil, err
	}

	answer := make(chan message, 1)
	b.lock.Lock()
	b.nextServerID++
	serverID := b.nextServerID
	b.pending[serverID] = &pendingRequest{process: process, internal: answer}
	b.lock.Unlock()

	request, _ := json.Marshal(message{JSONRPC: "2.0", ID: numberID(serverID), Method: "initialize", Params: initParams})
	if err := process.writer.Write(request); err != nil {
		process.kill()
		return nil, err
	}
	var response message
	select {
	case response = <-answer:
	case <-time.After(initializeTimeout):
		process.kill()
		return nil, errors.New("initialize timed out")
	}
	if response.Error != nil {
		process.kill()
		return nil, fmt.Errorf("initialize failed: %s", response.Error.Message)
	}
	process.writer.Write(encodeNotification("initialized", map[string]any{}))

	b.lock.Lock()
	defer b.lock.Unlock()
	if b.closed {
		process.kill()
		return nil, errors.New("broker closed")
	}
	for _, document := range b.docs.snapshot() {
		process.writer.Write(encodeNotification("textDocument/didOpen", map[string]any{
			"textDocument": map[string]any{"uri": document.URI, "languageId": document.LanguageID, "version": document.Version, "text": document.Text},
		}))
	}
	b.server = process
	return response.Result, nil
}

func (b *Broker) spawn() (*serverProcess, error) {
	if len(b.config.Command) == 0 {
		return nil, errors.New("no language server command configured")
	}
	command := exec.Command(b.config.Command[0], b.config.Command[1:]...)
	if rootStat, err := os.Stat(b.config.Root); err == nil && rootStat.IsDir() {
		command.Dir = b.config.Root
	}
	command.Env = b.config.Env
	command.Stderr = stderrLogger{b.config.Logger}
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := command.Start(); err != nil {
		return nil, err
	}
	process := &serverProcess{command: command, stdin: stdin, writer: rpc.NewWriter(stdin)}
	go b.readServer(process, rpc.NewReader(stdout, maxServerMessage))
	return process, nil
}

func (b *Broker) readServer(process *serverProcess, reader *rpc.Reader) {
	for {
		payload, err := reader.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				b.config.Logger.Warn("language server output unreadable", "error", err)
			}
			break
		}
		b.handleServerMessage(process, payload)
	}
	process.kill()
	process.stdin.Close()
	process.command.Wait()
	b.serverExited(process)
}

// serverExited fails everything that was waiting on the dead process and, if it was the current
// one, restarts the server.
func (b *Broker) serverExited(process *serverProcess) {
	b.lock.Lock()
	var failed []*pendingRequest
	for serverID, request := range b.pending {
		if request.process == process {
			failed = append(failed, request)
			delete(b.pending, serverID)
		}
	}
	for outgoingID, request := range b.outgoing {
		if request.process == process {
			delete(b.outgoing, outgoingID)
		}
	}
	wasCurrent := b.server == process
	if wasCurrent {
		b.server = nil
		b.restarting = !b.closed
	}
	closed := b.closed
	b.lock.Unlock()

	for _, request := range failed {
		failure := message{Error: &respError{Code: codeServerRestarted, Message: "language server exited"}}
		if request.internal != nil {
			request.internal <- failure
			continue
		}
		request.owner.writer.Write(encodeError(request.originalID, codeServerRestarted, "language server restarted"))
	}
	if wasCurrent && !closed {
		b.restart()
	}
}

// restart retries boot with growing delays. ponytail: fixed linear backoff, no crash-loop memory across restarts.
func (b *Broker) restart() {
	for attempt := 1; attempt <= b.config.MaxRestarts; attempt++ {
		time.Sleep(b.config.RestartDelay * time.Duration(attempt))

		b.lock.Lock()
		closed, initParams := b.closed, b.initParams
		b.lock.Unlock()
		if closed {
			return
		}

		b.bootLock.Lock()
		_, err := b.boot(initParams)
		b.bootLock.Unlock()
		if err != nil {
			b.config.Logger.Warn("restart attempt failed", "attempt", attempt, "error", err)
			continue
		}
		b.lock.Lock()
		b.restarting = false
		b.epoch++
		epoch := b.epoch
		b.lock.Unlock()
		b.config.Logger.Info("language server restarted", "epoch", epoch)
		b.broadcast(encodeNotification("gobi/lspRestarted", map[string]any{"epoch": epoch}))
		return
	}
	b.lock.Lock()
	b.restarting = false
	b.lock.Unlock()
	b.broadcast(encodeNotification("gobi/lspFailed", map[string]any{"attempts": b.config.MaxRestarts}))
}

// ---- encoding helpers ----

type stderrLogger struct{ logger *slog.Logger }

func (sink stderrLogger) Write(chunk []byte) (int, error) {
	if text := strings.TrimSpace(string(chunk)); text != "" {
		sink.logger.Debug("language server stderr", "text", text)
	}
	return len(chunk), nil
}

func numberID(id int64) json.RawMessage { return json.RawMessage(strconv.FormatInt(id, 10)) }

func encodeResult(id, answer json.RawMessage) []byte {
	encoded, _ := json.Marshal(message{JSONRPC: "2.0", ID: id, Result: answer})
	return encoded
}

func encodeError(id json.RawMessage, code int, text string) []byte {
	encoded, _ := json.Marshal(message{JSONRPC: "2.0", ID: id, Error: &respError{Code: code, Message: text}})
	return encoded
}

func encodeNotification(method string, params any) []byte {
	notification := message{JSONRPC: "2.0", Method: method}
	if params != nil {
		notification.Params, _ = json.Marshal(params)
	}
	encoded, _ := json.Marshal(notification)
	return encoded
}
