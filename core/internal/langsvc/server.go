package langsvc

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"

	"gobi/core/internal/rpc"
)

const (
	maxMessage        = 256 << 20
	codeMethodMissing = -32601
	languageJSON      = "json"
	languageMarkdown  = "markdown"
)

type openDocument struct {
	languageID string
	text       string
}

type languageService struct {
	writer *rpc.Writer
	docs   map[string]*openDocument
}

// Serve runs the language service over LSP framing until the input ends or the client sends exit.
// Documents use full-text sync, so clients send the whole file on every change.
// ponytail: full sync re-sends the file per keystroke; fine for config and docs, switch to
// incremental sync if very large JSON or Markdown files feel slow.
func Serve(input io.Reader, output io.Writer) error {
	service := &languageService{writer: rpc.NewWriter(output), docs: map[string]*openDocument{}}
	reader := rpc.NewReader(input, maxMessage)
	for {
		payload, err := reader.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		if service.handle(payload) {
			return nil
		}
	}
}

type textDocumentParams struct {
	TextDocument struct {
		URI        string `json:"uri"`
		LanguageID string `json:"languageId"`
		Text       string `json:"text"`
	} `json:"textDocument"`
	ContentChanges []struct {
		Text string `json:"text"`
	} `json:"contentChanges"`
	Options struct {
		TabSize      int   `json:"tabSize"`
		InsertSpaces *bool `json:"insertSpaces"`
	} `json:"options"`
}

// handle processes one message and reports whether the client asked the server to exit.
func (service *languageService) handle(payload []byte) (exit bool) {
	var incoming struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(payload, &incoming) != nil || incoming.Method == "" {
		return false
	}
	var params textDocumentParams
	json.Unmarshal(incoming.Params, &params)
	uri := params.TextDocument.URI

	switch incoming.Method {
	case "initialize":
		service.reply(incoming.ID, map[string]any{
			"capabilities": map[string]any{
				"textDocumentSync":           map[string]any{"openClose": true, "change": 1},
				"documentFormattingProvider": true,
				"documentSymbolProvider":     true,
			},
			"serverInfo": map[string]any{"name": "gobi-langsvc"},
		})
	case "shutdown":
		service.reply(incoming.ID, nil)
	case "exit":
		return true
	case "textDocument/didOpen":
		service.docs[uri] = &openDocument{languageID: params.TextDocument.LanguageID, text: params.TextDocument.Text}
		service.publish(uri)
	case "textDocument/didChange":
		if doc := service.docs[uri]; doc != nil && len(params.ContentChanges) > 0 {
			doc.text = params.ContentChanges[len(params.ContentChanges)-1].Text
			service.publish(uri)
		}
	case "textDocument/didClose":
		if doc := service.docs[uri]; doc != nil {
			delete(service.docs, uri)
			service.clear(uri)
		}
	case "textDocument/formatting":
		service.reply(incoming.ID, service.format(uri, params))
	case "textDocument/documentSymbol":
		service.reply(incoming.ID, service.symbols(uri))
	case "gobi/markdownPreview":
		html := ""
		if doc := service.docs[uri]; doc != nil && languageOf(uri, doc) == languageMarkdown {
			html = renderMarkdown(doc.text)
		}
		service.reply(incoming.ID, map[string]string{"html": html})
	default:
		if len(incoming.ID) > 0 {
			service.send(map[string]any{"jsonrpc": "2.0", "id": incoming.ID, "error": map[string]any{"code": codeMethodMissing, "message": "method not found: " + incoming.Method}})
		}
	}
	return false
}

func (service *languageService) send(message map[string]any) {
	encoded, _ := json.Marshal(message)
	service.writer.Write(encoded)
}

func (service *languageService) reply(id json.RawMessage, answer any) {
	if len(id) == 0 {
		return
	}
	service.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": answer})
}

func languageOf(uri string, doc *openDocument) string {
	switch doc.languageID {
	case languageJSON, languageMarkdown:
		return doc.languageID
	}
	lowered := strings.ToLower(uri)
	switch {
	case strings.HasSuffix(lowered, ".json"):
		return languageJSON
	case strings.HasSuffix(lowered, ".md"), strings.HasSuffix(lowered, ".markdown"):
		return languageMarkdown
	}
	return ""
}

type diagnostic struct {
	Range    lspRange `json:"range"`
	Severity int      `json:"severity"`
	Source   string   `json:"source"`
	Message  string   `json:"message"`
}

func (service *languageService) publish(uri string) {
	doc := service.docs[uri]
	diagnostics := []diagnostic{}
	switch languageOf(uri, doc) {
	case languageJSON:
		diagnostics = jsonDiagnostics(doc.text)
	case languageMarkdown:
	default:
		return
	}
	service.sendDiagnostics(uri, diagnostics)
}

func (service *languageService) clear(uri string) { service.sendDiagnostics(uri, []diagnostic{}) }

func (service *languageService) sendDiagnostics(uri string, diagnostics []diagnostic) {
	notification, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
		"params": map[string]any{"uri": uri, "diagnostics": diagnostics},
	})
	service.writer.Write(notification)
}

func jsonDiagnostics(text string) []diagnostic {
	if strings.TrimSpace(text) == "" {
		return []diagnostic{}
	}
	_, problem := parseJSON(text)
	if problem == nil {
		return []diagnostic{}
	}
	end := problem.Offset
	if _, size := utf8.DecodeRuneInString(text[problem.Offset:]); size > 0 {
		end += size
	}
	index := newLineIndex(text)
	return []diagnostic{{Range: index.rangeOf(problem.Offset, end), Severity: 1, Source: "gobi-json", Message: capitalize(problem.Message)}}
}

func capitalize(text string) string {
	first, size := utf8.DecodeRuneInString(text)
	return string(unicode.ToUpper(first)) + text[size:]
}

type textEdit struct {
	Range   lspRange `json:"range"`
	NewText string   `json:"newText"`
}

// format returns one whole-document edit for valid JSON and nothing otherwise.
func (service *languageService) format(uri string, params textDocumentParams) []textEdit {
	doc := service.docs[uri]
	if doc == nil || languageOf(uri, doc) != languageJSON || strings.TrimSpace(doc.text) == "" {
		return []textEdit{}
	}
	if _, problem := parseJSON(doc.text); problem != nil {
		return []textEdit{}
	}
	indent := "  "
	switch {
	case params.Options.InsertSpaces != nil && !*params.Options.InsertSpaces:
		indent = "\t"
	case params.Options.TabSize > 0:
		indent = strings.Repeat(" ", params.Options.TabSize)
	}
	var formatted bytes.Buffer
	if json.Indent(&formatted, []byte(strings.TrimSpace(doc.text)), "", indent) != nil {
		return []textEdit{}
	}
	formatted.WriteByte('\n')
	if formatted.String() == doc.text {
		return []textEdit{}
	}
	index := newLineIndex(doc.text)
	return []textEdit{{Range: index.rangeOf(0, len(doc.text)), NewText: formatted.String()}}
}

type documentSymbol struct {
	Name           string           `json:"name"`
	Detail         string           `json:"detail,omitempty"`
	Kind           int              `json:"kind"`
	Range          lspRange         `json:"range"`
	SelectionRange lspRange         `json:"selectionRange"`
	Children       []documentSymbol `json:"children,omitempty"`
}

func (service *languageService) symbols(uri string) []documentSymbol {
	doc := service.docs[uri]
	if doc == nil {
		return []documentSymbol{}
	}
	index := newLineIndex(doc.text)
	switch languageOf(uri, doc) {
	case languageJSON:
		symbols, problem := parseJSON(doc.text)
		if problem != nil {
			return []documentSymbol{}
		}
		return jsonDocumentSymbols(index, symbols)
	case languageMarkdown:
		return markdownDocumentSymbols(index, markdownSymbols(doc.text))
	}
	return []documentSymbol{}
}

func jsonDocumentSymbols(index *lineIndex, symbols []jsonSymbol) []documentSymbol {
	converted := make([]documentSymbol, 0, len(symbols))
	for _, symbol := range symbols {
		converted = append(converted, documentSymbol{
			Name: symbol.Name, Detail: symbol.Detail, Kind: symbol.Kind,
			Range:          index.rangeOf(symbol.KeyStart, symbol.End),
			SelectionRange: index.rangeOf(symbol.KeyStart, symbol.KeyEnd),
			Children:       jsonDocumentSymbols(index, symbol.Children),
		})
	}
	return converted
}

func markdownDocumentSymbols(index *lineIndex, symbols []mdSymbol) []documentSymbol {
	converted := make([]documentSymbol, 0, len(symbols))
	for _, symbol := range symbols {
		start := index.lineStarts[symbol.StartLine]
		converted = append(converted, documentSymbol{
			Name: symbol.Name, Kind: symbolKindNamespace,
			Range:          index.rangeOf(start, index.lineEnd(symbol.EndLine)),
			SelectionRange: index.rangeOf(start, index.lineEnd(symbol.StartLine)),
			Children:       markdownDocumentSymbols(index, symbol.Children),
		})
	}
	return converted
}
