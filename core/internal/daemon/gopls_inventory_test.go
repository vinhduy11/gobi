//go:build unix

package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"gobi/core/internal/ipc"
	"gobi/core/internal/toolchain"
)

// lspProbe is a tiny LSP client for the inventory: it answers the server's own requests and records what it sees.
type lspProbe struct {
	t        *testing.T
	session  *ipc.Session
	mu       sync.Mutex
	messages chan map[string]json.RawMessage
	diag     map[string]json.RawMessage // uri -> last publishDiagnostics diagnostics
	applied  []string                   // summaries of workspace/applyEdit requests the server made
	nextID   int
}

func newProbe(t *testing.T, session *ipc.Session) *lspProbe {
	p := &lspProbe{t: t, session: session, messages: make(chan map[string]json.RawMessage, 256), diag: map[string]json.RawMessage{}}
	go func() {
		for {
			payload, err := session.Reader.Read()
			if err != nil {
				close(p.messages)
				return
			}
			var message map[string]json.RawMessage
			json.Unmarshal(payload, &message)
			p.messages <- message
		}
	}()
	return p
}

func (p *lspProbe) send(v any) {
	data, _ := json.Marshal(v)
	if err := p.session.Writer.Write(data); err != nil {
		p.t.Fatal(err)
	}
}

func (p *lspProbe) notify(method string, params any) {
	p.send(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}

// pump handles one incoming message; it reports the response when its id is the one asked for.
func (p *lspProbe) pump(message map[string]json.RawMessage, waitFor int) (response map[string]json.RawMessage, done bool) {
	var method string
	json.Unmarshal(message["method"], &method)
	_, hasID := message["id"]
	switch {
	case method == "" && hasID:
		return message, string(message["id"]) == fmt.Sprint(waitFor)
	case method != "" && hasID: // a request from the server
		var result any
		if method == "workspace/applyEdit" {
			result = map[string]any{"applied": true}
			p.applied = append(p.applied, summarizeEdit(message["params"]))
		}
		if method == "workspace/configuration" {
			result = []any{}
		}
		p.send(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(message["id"]), "result": result})
	case method == "textDocument/publishDiagnostics":
		var params struct {
			URI         string          `json:"uri"`
			Diagnostics json.RawMessage `json:"diagnostics"`
		}
		json.Unmarshal(message["params"], &params)
		p.diag[params.URI] = params.Diagnostics
	}
	return nil, false
}

func (p *lspProbe) request(method string, params any) map[string]json.RawMessage {
	p.nextID++
	id := p.nextID
	p.send(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	deadline := time.After(90 * time.Second)
	for {
		select {
		case message, ok := <-p.messages:
			if !ok {
				p.t.Fatalf("%s: connection closed", method)
			}
			if response, done := p.pump(message, id); done {
				return response
			}
		case <-deadline:
			p.t.Fatalf("%s: no response", method)
		}
	}
}

// drain handles incoming messages for a while, so diagnostics and applyEdit requests arrive.
func (p *lspProbe) drain(d time.Duration, until func() bool) {
	deadline := time.After(d)
	for {
		if until != nil && until() {
			return
		}
		select {
		case message, ok := <-p.messages:
			if !ok {
				return
			}
			p.pump(message, -1)
		case <-time.After(100 * time.Millisecond):
		case <-deadline:
			return
		}
	}
}

func summarizeEdit(params json.RawMessage) string {
	var p struct {
		Edit struct {
			Changes         map[string][]json.RawMessage `json:"changes"`
			DocumentChanges []map[string]json.RawMessage `json:"documentChanges"`
		} `json:"edit"`
	}
	json.Unmarshal(params, &p)
	var parts []string
	for uri, edits := range p.Edit.Changes {
		parts = append(parts, fmt.Sprintf("changes[%s]=%d edits", filepath.Base(uri), len(edits)))
	}
	for _, change := range p.Edit.DocumentChanges {
		if kind, ok := change["kind"]; ok {
			parts = append(parts, "resource op "+string(kind)+" "+string(change["uri"]))
			continue
		}
		var doc struct {
			URI string `json:"uri"`
		}
		json.Unmarshal(change["textDocument"], &doc)
		var edits []json.RawMessage
		json.Unmarshal(change["edits"], &edits)
		parts = append(parts, fmt.Sprintf("documentChanges[%s]=%d edits", filepath.Base(doc.URI), len(edits)))
	}
	return strings.Join(parts, "; ")
}

// TestGoplsCodeActionInventory records what a real gopls returns for the three actions Generate might delegate to it:
// implement interface (declare missing methods), generate test and fill struct. Opt in with GOBI_REAL_GOPLS=1; the
// findings are written up in docs/implement/generate.md ("gopls inventory"). Run with -v to see the table.
func TestGoplsCodeActionInventory(t *testing.T) {
	if os.Getenv("GOBI_REAL_GOPLS") != "1" {
		t.Skip("set GOBI_REAL_GOPLS=1 to run against the installed gopls")
	}
	goplsPath, err := toolchain.FromOS().Find("gopls")
	if err != nil {
		t.Skipf("gopls not installed: %v", err)
	}
	root := t.TempDir()
	files := map[string]string{
		"go.mod":         "module example.com/inv\n\ngo 1.22\n",
		"store/store.go": "package store\n\ntype Store interface {\n\tGet(id string) (string, error)\n\tPut(id, value string) error\n}\n\ntype Mem struct{}\n\nvar _ Store = (*Mem)(nil)\n",
		"calc.go":        "package inv\n\nimport \"errors\"\n\nfunc Divide(a, b int) (int, error) {\n\tif b == 0 {\n\t\treturn 0, errors.New(\"divide by zero\")\n\t}\n\treturn a / b, nil\n}\n",
		"fill.go":        "package inv\n\ntype Server struct {\n\tAddr string\n\tPort int\n}\n\nvar S = Server{}\n",
	}
	for name, content := range files {
		os.MkdirAll(filepath.Dir(filepath.Join(root, name)), 0o755)
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	socketPath, stop := startDaemon(t, map[string][]string{"go": {goplsPath}})
	defer stop()
	session, err := ipc.Dial(socketPath, ipc.Hello{ClientVersion: "test", Channel: "lsp", WorkspaceRoot: root, Trusted: true})
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	p := newProbe(t, session)

	kinds := []string{"quickfix", "refactor", "refactor.extract", "refactor.rewrite", "source", "source.addTest", "source.organizeImports"}
	p.request("initialize", map[string]any{
		"processId": nil, "rootUri": "file://" + root,
		"workspaceFolders": []any{map[string]any{"uri": "file://" + root, "name": "inv"}},
		"capabilities": map[string]any{
			"workspace": map[string]any{"applyEdit": true, "configuration": true, "workspaceEdit": map[string]any{"documentChanges": true, "resourceOperations": []string{"create", "rename", "delete"}}},
			"textDocument": map[string]any{
				"publishDiagnostics": map[string]any{},
				"codeAction": map[string]any{
					"dataSupport": true, "isPreferredSupport": true, "disabledSupport": true,
					"resolveSupport":           map[string]any{"properties": []string{"edit"}},
					"codeActionLiteralSupport": map[string]any{"codeActionKind": map[string]any{"valueSet": kinds}},
				},
			},
		},
	})
	p.notify("initialized", map[string]any{})
	for name, content := range files {
		if strings.HasSuffix(name, ".go") {
			p.notify("textDocument/didOpen", map[string]any{"textDocument": map[string]any{"uri": "file://" + filepath.Join(root, name), "languageId": "go", "version": 1, "text": content}})
		}
	}
	storeURI := "file://" + filepath.Join(root, "store", "store.go")
	p.drain(60*time.Second, func() bool { d := p.diag[storeURI]; return len(d) > 2 })

	type probeCase struct {
		name, file string
		rng        map[string]any
		only       []string
	}
	position := func(line, char int) map[string]int { return map[string]int{"line": line, "character": char} }
	// the range of the first diagnostic ("*Mem does not implement Store"), as an editor would send it
	var published []struct {
		Range map[string]any `json:"range"`
	}
	json.Unmarshal(p.diag[storeURI], &published)
	if len(published) == 0 {
		t.Fatalf("gopls published no diagnostic for the store package: %s", p.diag[storeURI])
	}
	storeRange := published[0].Range
	cases := []probeCase{
		{"implement interface (missing methods)", "store/store.go", storeRange, nil},
		{"implement interface, quickfix only", "store/store.go", storeRange, []string{"quickfix"}},
		{"generate test (cursor on Divide)", "calc.go", map[string]any{"start": position(4, 6), "end": position(4, 6)}, nil},
		{"generate test, source.addTest only", "calc.go", map[string]any{"start": position(4, 6), "end": position(4, 6)}, []string{"source.addTest"}},
		{"fill struct (cursor inside Server{})", "fill.go", map[string]any{"start": position(7, 15), "end": position(7, 15)}, nil},
	}
	for _, c := range cases {
		uri := "file://" + filepath.Join(root, c.file)
		var diagnostics json.RawMessage = []byte("[]")
		if c.file == "store/store.go" {
			diagnostics = p.diag[uri]
			if diagnostics == nil {
				diagnostics = []byte("[]")
			}
		}
		context := map[string]any{"diagnostics": diagnostics}
		if c.only != nil {
			context["only"] = c.only
		}
		response := p.request("textDocument/codeAction", map[string]any{"textDocument": map[string]any{"uri": uri}, "range": c.rng, "context": context})
		var actions []map[string]json.RawMessage
		json.Unmarshal(response["result"], &actions)
		t.Logf("== %s: %d action(s)", c.name, len(actions))
		for _, a := range actions {
			var title, kind string
			json.Unmarshal(a["title"], &title)
			json.Unmarshal(a["kind"], &kind)
			var command struct {
				Command string `json:"command"`
			}
			json.Unmarshal(a["command"], &command)
			_, hasEdit := a["edit"]
			_, hasData := a["data"]
			line := fmt.Sprintf("title=%q kind=%s edit=%v command=%q data=%v", title, kind, hasEdit && string(a["edit"]) != "null", command.Command, hasData)
			if hasEdit && string(a["edit"]) != "null" {
				line += " editShape=" + summarizeEdit(mustJSON(map[string]json.RawMessage{"edit": a["edit"]}))
			}
			switch {
			case !hasEdit && hasData:
				resolved := p.request("codeAction/resolve", mapFromRaw(a))
				var r map[string]json.RawMessage
				json.Unmarshal(resolved["result"], &r)
				if string(r["edit"]) != "" && string(r["edit"]) != "null" {
					line += " | resolve -> edit " + summarizeEdit(mustJSON(map[string]json.RawMessage{"edit": r["edit"]}))
				} else {
					line += " | resolve -> no edit"
				}
			case command.Command != "" && !hasEdit:
				p.applied = nil
				var args json.RawMessage = a["command"]
				var full struct {
					Command   string          `json:"command"`
					Arguments json.RawMessage `json:"arguments"`
				}
				json.Unmarshal(args, &full)
				result := p.request("workspace/executeCommand", map[string]any{"command": full.Command, "arguments": full.Arguments})
				p.drain(2*time.Second, nil)
				line += fmt.Sprintf(" | executeCommand -> result=%s error=%s applyEdit=%v", result["result"], result["error"], p.applied)
			}
			t.Log("   " + line)
		}
	}
}

func mustJSON(v any) json.RawMessage { data, _ := json.Marshal(v); return data }

func mapFromRaw(m map[string]json.RawMessage) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	return out
}
