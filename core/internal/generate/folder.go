package generate

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// The Explorer's Generate ▸ items: each writes one new Go file into the folder. They are pattern definitions that are
// offered for a folder (KindFolder) instead of a caret, named after an answer, and always target a new file.

// KindFolder is the context of an item chosen on a folder in the Explorer.
const KindFolder = "folder"

// folderCatalogue lists the folder items in the order of the Explorer submenu.
var folderCatalogue = []patternDef{
	{
		ID: "folder-http-handler", Title: "HTTP Handler…", Folder: true, FileKey: "resource", FileSuffix: "_handler",
		Detail: "a handler type with routes (Go 1.22 method patterns), JSON replies and a logger",
		Params: []ParamSpec{{Key: "resource", Label: "Resource", Kind: kindType, Default: []string{"Users"}}},
		Tmpl: `// {{.resource}}Handler serves the /{{lower .resource}} endpoints.
type {{.resource}}Handler struct {
	logger *{{pkg "log/slog"}}.Logger
}

// New{{.resource}}Handler returns a handler that logs through logger.
func New{{.resource}}Handler(logger *{{pkg "log/slog"}}.Logger) *{{.resource}}Handler {
	return &{{.resource}}Handler{logger: logger}
}

// Register adds the routes to mux. Method and wildcard patterns need Go 1.22 or later.
func (h *{{.resource}}Handler) Register(mux *{{pkg "net/http"}}.ServeMux) {
	mux.HandleFunc("GET /{{lower .resource}}", h.list)
	mux.HandleFunc("GET /{{lower .resource}}/{id}", h.get)
	mux.HandleFunc("POST /{{lower .resource}}", h.create)
}

func (h *{{.resource}}Handler) list(w {{pkg "net/http"}}.ResponseWriter, r *{{pkg "net/http"}}.Request) {
	h.writeJSON(w, {{pkg "net/http"}}.StatusOK, []string{}) // TODO: return the real list
}

func (h *{{.resource}}Handler) get(w {{pkg "net/http"}}.ResponseWriter, r *{{pkg "net/http"}}.Request) {
	h.writeJSON(w, {{pkg "net/http"}}.StatusOK, map[string]string{"id": r.PathValue("id")}) // TODO: load it
}

func (h *{{.resource}}Handler) create(w {{pkg "net/http"}}.ResponseWriter, r *{{pkg "net/http"}}.Request) {
	var in map[string]any
	if err := {{pkg "encoding/json"}}.NewDecoder(r.Body).Decode(&in); err != nil {
		{{pkg "net/http"}}.Error(w, "invalid JSON body", {{pkg "net/http"}}.StatusBadRequest)
		return
	}
	h.writeJSON(w, {{pkg "net/http"}}.StatusCreated, in) // TODO: store it
}

func (h *{{.resource}}Handler) writeJSON(w {{pkg "net/http"}}.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := {{pkg "encoding/json"}}.NewEncoder(w).Encode(v); err != nil {
		h.logger.Error("write response", "err", err)
	}
}`,
	},
	{
		ID: "folder-consumer", Title: "Message Consumer…", Folder: true, FileKey: "name", FileSuffix: "_consumer",
		Detail: "a consumer loop over a channel of messages; feed the channel from your broker client",
		Params: []ParamSpec{{Key: "name", Label: "Messages", Kind: kindType, Default: []string{"Orders"}}},
		Tmpl: `// {{.name}}Message is one delivery from the broker.
type {{.name}}Message struct {
	Key, Value []byte
}

// {{.name}}Handler processes one message. A returned error is logged and the consumer moves on to the next message.
type {{.name}}Handler func(ctx {{pkg "context"}}.Context, msg {{.name}}Message) error

// {{.name}}Consumer reads messages from a channel until the context ends or the channel closes. Feed the channel from your
// client library (a Kafka reader, an MQTT subscription, ...) so this loop stays free of any broker dependency.
type {{.name}}Consumer struct {
	source <-chan {{.name}}Message
	handle {{.name}}Handler
	logger *{{pkg "log/slog"}}.Logger
}

// New{{.name}}Consumer returns a consumer that passes every message from source to handle.
func New{{.name}}Consumer(source <-chan {{.name}}Message, handle {{.name}}Handler, logger *{{pkg "log/slog"}}.Logger) *{{.name}}Consumer {
	return &{{.name}}Consumer{source: source, handle: handle, logger: logger}
}

// Run blocks until ctx is cancelled (it returns ctx.Err()) or the source is closed (it returns nil).
func (c *{{.name}}Consumer) Run(ctx {{pkg "context"}}.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg, ok := <-c.source:
			if !ok {
				return nil
			}
			if err := c.handle(ctx, msg); err != nil {
				c.logger.Error("handle message", "key", string(msg.Key), "err", err)
			}
		}
	}
}`,
	},
	{
		ID: "folder-repository", Title: "Repository…", Folder: true, FileKey: "entity", FileSuffix: "_repository",
		Detail: "an entity, a repository interface and an in-memory implementation to replace with your database",
		Params: []ParamSpec{
			{Key: "entity", Label: "Entity", Kind: kindType, Default: []string{"User"}},
			{Key: "fields", Label: "Fields", Kind: kindFields, Multi: true, Default: []string{"Name string"}},
		},
		Tmpl: `// Err{{.entity}}NotFound is returned when no {{.entity}} has the given ID; test for it with errors.Is.
var Err{{.entity}}NotFound = {{pkg "errors"}}.New("{{lower .entity}} not found")

// {{.entity}} is the stored record.
type {{.entity}} struct {
	ID string
{{- range .fields}}
	{{.Export}} {{.Type}}
{{- end}}
}

// {{.entity}}Repository stores {{.entity}} records.
type {{.entity}}Repository interface {
	Get(ctx {{pkg "context"}}.Context, id string) ({{.entity}}, error)
	Save(ctx {{pkg "context"}}.Context, item {{.entity}}) error
	Delete(ctx {{pkg "context"}}.Context, id string) error
}

// Memory{{.entity}}Repository keeps records in a map and is safe for concurrent use. Replace it with an implementation
// backed by your database; the interface stays the same.
type Memory{{.entity}}Repository struct {
	mu    {{pkg "sync"}}.RWMutex
	items map[string]{{.entity}}
}

var _ {{.entity}}Repository = (*Memory{{.entity}}Repository)(nil)

// NewMemory{{.entity}}Repository returns an empty repository.
func NewMemory{{.entity}}Repository() *Memory{{.entity}}Repository {
	return &Memory{{.entity}}Repository{items: map[string]{{.entity}}{}}
}

// Get returns the record with the given ID, or an error wrapping Err{{.entity}}NotFound.
func (r *Memory{{.entity}}Repository) Get(ctx {{pkg "context"}}.Context, id string) ({{.entity}}, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	item, ok := r.items[id]
	if !ok {
		return {{.entity}}{}, {{pkg "fmt"}}.Errorf("get %q: %w", id, Err{{.entity}}NotFound)
	}
	return item, nil
}

// Save stores item under its ID, replacing any earlier record.
func (r *Memory{{.entity}}Repository) Save(ctx {{pkg "context"}}.Context, item {{.entity}}) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.items[item.ID] = item
	return nil
}

// Delete removes the record with the given ID, or returns an error wrapping Err{{.entity}}NotFound.
func (r *Memory{{.entity}}Repository) Delete(ctx {{pkg "context"}}.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.items[id]; !ok {
		return {{pkg "fmt"}}.Errorf("delete %q: %w", id, Err{{.entity}}NotFound)
	}
	delete(r.items, id)
	return nil
}`,
	},
	{
		ID: "folder-config", Title: "Config Loader…", Folder: true, FileKey: "type", FileSuffix: "_loader",
		Detail: "a config struct read from environment variables (string, int, bool and time.Duration fields)",
		Params: []ParamSpec{
			{Key: "type", Label: "Config type", Kind: kindType, Default: []string{"Config"}},
			{Key: "prefix", Label: "Variable prefix", Kind: kindType, Default: []string{"APP"}},
			{Key: "fields", Label: "Fields", Kind: kindFields, Multi: true, Default: []string{"Addr string", "ReadTimeout time.Duration", "Debug bool"}},
		},
		Tmpl: `// {{.type}} holds the settings read from the environment.
type {{.type}} struct {
{{- range .fields}}
	{{.Export}} {{.Type}}
{{- end}}
}

// Load{{.type}} reads a {{.type}} from the variables named {{.prefix}}_<FIELD>. A variable that is not set keeps the
// field's zero value; one that cannot be parsed is an error.
func Load{{.type}}() ({{.type}}, error) {
	var cfg {{.type}}
{{- range .fields}}
{{- $env := printf "%s_%s" $.prefix (upper (snake .Name))}}
	if v, ok := {{pkg "os"}}.LookupEnv("{{$env}}"); ok {
{{- if eq .Type "string"}}
		cfg.{{.Export}} = v
{{- else if eq .Type "int"}}
		n, err := {{pkg "strconv"}}.Atoi(v)
		if err != nil {
			return cfg, {{pkg "fmt"}}.Errorf("{{$env}}: %w", err)
		}
		cfg.{{.Export}} = n
{{- else if eq .Type "bool"}}
		b, err := {{pkg "strconv"}}.ParseBool(v)
		if err != nil {
			return cfg, {{pkg "fmt"}}.Errorf("{{$env}}: %w", err)
		}
		cfg.{{.Export}} = b
{{- else if eq .Type "time.Duration"}}
		d, err := {{pkg "time"}}.ParseDuration(v)
		if err != nil {
			return cfg, {{pkg "fmt"}}.Errorf("{{$env}}: %w", err)
		}
		cfg.{{.Export}} = d
{{- else}}
		{{fail (printf "field %s: type %s cannot be read from the environment (use string, int, bool or time.Duration)" .Name .Type)}}
{{- end}}
	}
{{- end}}
	return cfg, nil
}`,
	},
	{
		ID: "folder-worker", Title: "Worker with Graceful Shutdown…", Folder: true, FileKey: "name", FileSuffix: "_worker",
		Detail: "a periodic worker that finishes the work in flight when the context ends or SIGINT/SIGTERM arrives",
		Params: []ParamSpec{{Key: "name", Label: "Worker", Kind: kindType, Default: []string{"Worker"}}},
		Tmpl: `// {{.name}} calls work every interval until its context ends. The call in progress is allowed to finish.
type {{.name}} struct {
	interval {{pkg "time"}}.Duration
	work     func(ctx {{pkg "context"}}.Context) error
	logger   *{{pkg "log/slog"}}.Logger
}

// New{{.name}} returns a worker that runs work every interval.
func New{{.name}}(interval {{pkg "time"}}.Duration, work func(ctx {{pkg "context"}}.Context) error, logger *{{pkg "log/slog"}}.Logger) *{{.name}} {
	return &{{.name}}{interval: interval, work: work, logger: logger}
}

// Run blocks until ctx is cancelled, then returns once the work in progress has finished. work receives a context that is
// not cancelled with ctx, so it completes instead of being cut off; keep it short enough for your shutdown deadline.
func (w *{{.name}}) Run(ctx {{pkg "context"}}.Context) error {
	ticker := {{pkg "time"}}.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := w.work({{pkg "context"}}.WithoutCancel(ctx)); err != nil {
				w.logger.Error("work failed", "err", err)
			}
		}
	}
}

// RunUntilSignal runs the worker until the process receives SIGINT or SIGTERM, then returns after the work in progress.
func (w *{{.name}}) RunUntilSignal() error {
	ctx, stop := {{pkg "os/signal"}}.NotifyContext({{pkg "context"}}.Background(), {{pkg "os"}}.Interrupt, {{pkg "syscall"}}.SIGTERM)
	defer stop()
	return w.Run(ctx)
}`,
	},
}

// folderItems are the items the Explorer offers on a folder.
func folderItems() []Item {
	items := make([]Item, len(folderCatalogue))
	for i, d := range folderCatalogue {
		items[i] = Item{ID: d.ID, Title: d.Title, Detail: d.Detail, Params: d.Params}
	}
	return items
}

// fileName is the file a folder item writes: the answer to FileKey in snake_case plus the suffix, for example
// users_handler.go.
func (d patternDef) fileName(req Request) (string, error) {
	var spec ParamSpec
	for _, p := range d.Params {
		if p.Key == d.FileKey {
			spec = p
		}
	}
	values := spec.Default
	for _, v := range req.Values {
		if v.Key == d.FileKey && len(v.Values) > 0 && strings.TrimSpace(v.Values[0]) != "" {
			values = v.Values
		}
	}
	name, err := goName(values[0])
	if err != nil {
		return "", fmt.Errorf("%s: %w", spec.Label, err)
	}
	return strings.ToLower(strings.Join(words(name), "_")) + d.FileSuffix + ".go", nil
}

// folderResult writes the rendered item as a new file in the folder.
func folderResult(def patternDef, req Request, result Result, needs []importSpec) (Result, error) {
	name, err := def.fileName(req)
	if err != nil {
		return Result{}, err
	}
	dir := req.Path
	if fi, err := osStat(dir); err != nil || !fi.IsDir() {
		return Result{}, fmt.Errorf("%s is not a folder", filepath.Base(dir))
	}
	target := filepath.Join(dir, name)
	if _, err := osStat(target); err == nil {
		return Result{}, fmt.Errorf("%s already exists", name)
	}
	pkg := req.Package
	if pkg == "" {
		pkg = patternPackage(req, nil, dir)
	}
	content, err := insert(nil, Context{Package: pkg}, result.Text, needs)
	if err != nil {
		return Result{}, err
	}
	result.Files = []File{{Path: target, Content: content[0].Text}}
	return result, nil
}

// failTemplate stops a template with a message for the user (a field type the item cannot handle).
func failTemplate(message string) (string, error) { return "", errors.New(message) }
