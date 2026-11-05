package langsvc

import (
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"gobi/core/internal/rpc"
)

type rawMessage struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

type serverClient struct {
	t             *testing.T
	writer        *rpc.Writer
	lock          sync.Mutex
	nextID        int
	waiting       map[string]chan rawMessage
	notifications chan rawMessage
	finished      chan error
}

func startServer(t *testing.T) *serverClient {
	t.Helper()
	toServer, serverInput := io.Pipe()
	serverOutput, fromServer := io.Pipe()
	client := &serverClient{
		t:             t,
		writer:        rpc.NewWriter(serverInput),
		waiting:       map[string]chan rawMessage{},
		notifications: make(chan rawMessage, 64),
		finished:      make(chan error, 1),
	}
	go func() {
		client.finished <- Serve(toServer, fromServer)
		fromServer.Close()
	}()
	go func() {
		reader := rpc.NewReader(serverOutput, 64<<20)
		for {
			payload, err := reader.Read()
			if err != nil {
				return
			}
			var incoming rawMessage
			json.Unmarshal(payload, &incoming)
			if incoming.Method == "" && len(incoming.ID) > 0 {
				client.lock.Lock()
				waiter := client.waiting[string(incoming.ID)]
				client.lock.Unlock()
				if waiter != nil {
					waiter <- incoming
				}
			} else {
				client.notifications <- incoming
			}
		}
	}()
	t.Cleanup(func() { serverInput.Close() })
	return client
}

func (client *serverClient) call(method string, params any) rawMessage {
	client.t.Helper()
	client.lock.Lock()
	client.nextID++
	id := client.nextID
	waiter := make(chan rawMessage, 1)
	client.waiting[jsonNumber(id)] = waiter
	client.lock.Unlock()

	encoded, _ := json.Marshal(params)
	request, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(encoded)})
	if err := client.writer.Write(request); err != nil {
		client.t.Fatal(err)
	}
	select {
	case response := <-waiter:
		return response
	case <-time.After(5 * time.Second):
		client.t.Fatalf("no response to %s", method)
		return rawMessage{}
	}
}

func (client *serverClient) notify(method string, params any) {
	client.t.Helper()
	notification, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
	if err := client.writer.Write(notification); err != nil {
		client.t.Fatal(err)
	}
}

func jsonNumber(id int) string {
	encoded, _ := json.Marshal(id)
	return string(encoded)
}

func (client *serverClient) open(uri, languageID, text string) {
	client.t.Helper()
	client.notify("textDocument/didOpen", map[string]any{
		"textDocument": map[string]any{"uri": uri, "languageId": languageID, "version": 1, "text": text},
	})
}

func (client *serverClient) change(uri string, version int, text string) {
	client.t.Helper()
	client.notify("textDocument/didChange", map[string]any{
		"textDocument":   map[string]any{"uri": uri, "version": version},
		"contentChanges": []map[string]any{{"text": text}},
	})
}

type diagnosticsParams struct {
	URI         string `json:"uri"`
	Diagnostics []struct {
		Range    lspRange `json:"range"`
		Severity int      `json:"severity"`
		Source   string   `json:"source"`
		Message  string   `json:"message"`
	} `json:"diagnostics"`
}

func (client *serverClient) nextDiagnostics() diagnosticsParams {
	client.t.Helper()
	select {
	case notification := <-client.notifications:
		if notification.Method != "textDocument/publishDiagnostics" {
			client.t.Fatalf("unexpected notification %s", notification.Method)
		}
		var params diagnosticsParams
		json.Unmarshal(notification.Params, &params)
		return params
	case <-time.After(5 * time.Second):
		client.t.Fatal("no diagnostics published")
		return diagnosticsParams{}
	}
}

func decode[T any](t *testing.T, response rawMessage) T {
	t.Helper()
	if response.Error != nil {
		t.Fatalf("error response: %+v", response.Error)
	}
	var decoded T
	if err := json.Unmarshal(response.Result, &decoded); err != nil {
		t.Fatalf("decode %s: %v", response.Result, err)
	}
	return decoded
}

func TestInitializeAdvertisesTheBuiltInFeatures(t *testing.T) {
	client := startServer(t)
	response := client.call("initialize", map[string]any{"capabilities": map[string]any{}})
	capabilities := decode[struct {
		Capabilities struct {
			TextDocumentSync           struct{ Change int } `json:"textDocumentSync"`
			DocumentFormattingProvider bool                 `json:"documentFormattingProvider"`
			DocumentSymbolProvider     bool                 `json:"documentSymbolProvider"`
		} `json:"capabilities"`
	}](t, response).Capabilities
	if capabilities.TextDocumentSync.Change != 1 || !capabilities.DocumentFormattingProvider || !capabilities.DocumentSymbolProvider {
		t.Fatalf("got %+v", capabilities)
	}
}

func TestJSONDiagnosticsFollowEdits(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})
	const uri = "file:///work/config.json"

	client.open(uri, "json", "{\n  \"a\": 1,\n}")
	published := client.nextDiagnostics()
	if published.URI != uri || len(published.Diagnostics) != 1 {
		t.Fatalf("got %+v", published)
	}
	problem := published.Diagnostics[0]
	if problem.Range.Start.Line != 2 || problem.Range.Start.Character != 0 || problem.Severity != 1 || problem.Source != "gobi-json" || problem.Message == "" {
		t.Fatalf("diagnostic %+v", problem)
	}

	client.change(uri, 2, "{\n  \"a\": 1\n}")
	if fixed := client.nextDiagnostics(); len(fixed.Diagnostics) != 0 {
		t.Fatalf("fixed document must publish no diagnostics, got %+v", fixed)
	}

	client.change(uri, 3, "{\"emoji\": \"😀\" x}")
	if utf16 := client.nextDiagnostics(); len(utf16.Diagnostics) != 1 || utf16.Diagnostics[0].Range.Start.Character != 15 {
		t.Fatalf("columns count UTF-16 units (the emoji is two), got %+v", utf16)
	}

	client.notify("textDocument/didClose", map[string]any{"textDocument": map[string]any{"uri": uri}})
	if closed := client.nextDiagnostics(); len(closed.Diagnostics) != 0 {
		t.Fatalf("closing clears diagnostics, got %+v", closed)
	}
}

func TestBlankJSONAndMarkdownPublishNoProblems(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})

	client.open("file:///work/empty.json", "json", "  \n")
	if published := client.nextDiagnostics(); len(published.Diagnostics) != 0 {
		t.Fatalf("a blank json file is not an error, got %+v", published)
	}
	client.open("file:///work/readme.md", "markdown", "# hi")
	if published := client.nextDiagnostics(); len(published.Diagnostics) != 0 {
		t.Fatalf("markdown has no diagnostics, got %+v", published)
	}
}

func TestJSONFormatting(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})
	const uri = "file:///work/config.json"
	client.open(uri, "json", `{"a":1,"b":[1,2]}`)
	client.nextDiagnostics()

	spaces := decode[[]textEdit](t, client.call("textDocument/formatting", map[string]any{
		"textDocument": map[string]any{"uri": uri},
		"options":      map[string]any{"tabSize": 2, "insertSpaces": true},
	}))
	if len(spaces) != 1 || spaces[0].NewText != "{\n  \"a\": 1,\n  \"b\": [\n    1,\n    2\n  ]\n}\n" {
		t.Fatalf("got %+v", spaces)
	}
	if end := spaces[0].Range.End; spaces[0].Range.Start != (position{0, 0}) || end.Line != 0 || end.Character != 17 {
		t.Fatalf("the edit must cover the whole document, got %+v", spaces[0].Range)
	}

	tabs := decode[[]textEdit](t, client.call("textDocument/formatting", map[string]any{
		"textDocument": map[string]any{"uri": uri},
		"options":      map[string]any{"tabSize": 4, "insertSpaces": false},
	}))
	if len(tabs) != 1 || !strings.HasPrefix(tabs[0].NewText, "{\n\t\"a\": 1") {
		t.Fatalf("got %+v", tabs)
	}

	client.change(uri, 2, `{"a":`)
	client.nextDiagnostics()
	if broken := decode[[]textEdit](t, client.call("textDocument/formatting", map[string]any{"textDocument": map[string]any{"uri": uri}})); len(broken) != 0 {
		t.Fatalf("an invalid document is not reformatted, got %+v", broken)
	}
}

func TestAlreadyFormattedJSONNeedsNoEdit(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})
	const uri = "file:///work/ok.json"
	client.open(uri, "json", "{\n  \"a\": 1\n}\n")
	client.nextDiagnostics()
	if edits := decode[[]textEdit](t, client.call("textDocument/formatting", map[string]any{"textDocument": map[string]any{"uri": uri}})); len(edits) != 0 {
		t.Fatalf("got %+v", edits)
	}
}

func TestDocumentSymbols(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})

	client.open("file:///work/c.json", "json", "{\n  \"server\": {\"port\": 80},\n  \"tags\": [\"a\"]\n}")
	client.nextDiagnostics()
	jsonSymbols := decode[[]documentSymbol](t, client.call("textDocument/documentSymbol", map[string]any{"textDocument": map[string]any{"uri": "file:///work/c.json"}}))
	if len(jsonSymbols) != 2 || jsonSymbols[0].Name != "server" || jsonSymbols[0].Children[0].Name != "port" || jsonSymbols[1].Kind != symbolKindArray {
		t.Fatalf("json: %+v", jsonSymbols)
	}
	if jsonSymbols[0].SelectionRange.Start.Line != 1 || jsonSymbols[0].SelectionRange.Start.Character != 2 {
		t.Fatalf("selection range is the key, got %+v", jsonSymbols[0].SelectionRange)
	}

	client.open("file:///work/r.md", "markdown", "# Title\n## Part\n")
	client.nextDiagnostics()
	markdown := decode[[]documentSymbol](t, client.call("textDocument/documentSymbol", map[string]any{"textDocument": map[string]any{"uri": "file:///work/r.md"}}))
	if len(markdown) != 1 || markdown[0].Name != "Title" || len(markdown[0].Children) != 1 || markdown[0].Children[0].Name != "Part" {
		t.Fatalf("markdown: %+v", markdown)
	}
	if markdown[0].SelectionRange.Start.Line != 0 || markdown[0].Range.End.Line != 1 {
		t.Fatalf("markdown ranges: %+v", markdown[0])
	}
}

func TestMarkdownPreviewRequest(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})
	const uri = "file:///work/r.md"
	client.open(uri, "markdown", "# Title\n\n**bold** <script>alert(1)</script>\n")
	client.nextDiagnostics()

	preview := decode[struct {
		HTML string `json:"html"`
	}](t, client.call("gobi/markdownPreview", map[string]any{"textDocument": map[string]any{"uri": uri}}))
	if !strings.Contains(preview.HTML, "<h1") || !strings.Contains(preview.HTML, "<strong>bold</strong>") || strings.Contains(preview.HTML, "<script") {
		t.Fatalf("got %s", preview.HTML)
	}
}

func TestRequestsForUnknownDocumentsAndMethods(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})

	if symbols := decode[[]documentSymbol](t, client.call("textDocument/documentSymbol", map[string]any{"textDocument": map[string]any{"uri": "file:///nope.json"}})); len(symbols) != 0 {
		t.Fatalf("unknown document has no symbols, got %+v", symbols)
	}
	if response := client.call("workspace/executeCommand", map[string]any{}); response.Error == nil || response.Error.Code != -32601 {
		t.Fatalf("want method-not-found, got %+v", response)
	}
}

func TestShutdownThenExitEndsTheServer(t *testing.T) {
	client := startServer(t)
	client.call("initialize", map[string]any{})
	client.call("shutdown", nil)
	client.notify("exit", nil)
	select {
	case err := <-client.finished:
		if err != nil {
			t.Fatalf("clean exit expected, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop")
	}
}
