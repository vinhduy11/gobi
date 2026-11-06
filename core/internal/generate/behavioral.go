package generate

// The behavioral patterns: how objects share work and talk to each other.
var behavioral = []patternDef{
	{
		ID: "chain-of-responsibility", Title: "Chain of Responsibility", Group: "behavioral",
		Detail: "a handler interface and a slice of handlers tried in order",
		Params: []ParamSpec{
			{Key: "handler", Label: "Handler interface", Kind: kindType, Default: []string{"Handler"}},
			{Key: "request", Label: "Request type", Kind: kindTypeExpr, Default: []string{"string"}},
		},
		Tmpl: `{{.header}}
{{$ctx := pkg "context"}}
// {{.handler}} is one link of a chain: it reports whether it handled req, and false passes req on to the next link.
type {{.handler}} interface {
	Handle(ctx {{$ctx}}.Context, req {{.request}}) bool
}

// {{.handler}}Func lets an ordinary function be a {{.handler}}.
type {{.handler}}Func func(ctx {{$ctx}}.Context, req {{.request}}) bool

// Handle calls f.
func (f {{.handler}}Func) Handle(ctx {{$ctx}}.Context, req {{.request}}) bool { return f(ctx, req) }

// {{.handler}}Chain tries its links in order until one handles the request.
type {{.handler}}Chain []{{.handler}}

// Handle reports whether any link handled req.
func (c {{.handler}}Chain) Handle(ctx {{$ctx}}.Context, req {{.request}}) bool {
	for _, link := range c {
		if link.Handle(ctx, req) {
			return true
		}
	}
	return false
}`,
	},
	{
		ID: "command", Title: "Command", Group: "behavioral",
		Detail: "a Command interface with Execute and Undo, and an invoker with history",
		Params: []ParamSpec{
			{Key: "command", Label: "Command interface", Kind: kindType, Default: []string{"Command"}},
		},
		Tmpl: `{{.header}}
{{$ctx := pkg "context"}}{{$fmt := pkg "fmt"}}
// {{.command}} is an action that can be undone.
type {{.command}} interface {
	Execute(ctx {{$ctx}}.Context) error
	Undo(ctx {{$ctx}}.Context) error
}

// {{.command}}History runs commands and remembers them so they can be undone, latest first. It is not safe for concurrent use.
type {{.command}}History struct {
	done []{{.command}}
}

// Do executes cmd and, when it succeeds, records it.
func (h *{{.command}}History) Do(ctx {{$ctx}}.Context, cmd {{.command}}) error {
	if err := cmd.Execute(ctx); err != nil {
		return {{$fmt}}.Errorf("execute command: %w", err)
	}
	h.done = append(h.done, cmd)
	return nil
}

// Undo reverts the most recent command; it does nothing when the history is empty.
func (h *{{.command}}History) Undo(ctx {{$ctx}}.Context) error {
	if len(h.done) == 0 {
		return nil
	}
	last := h.done[len(h.done)-1]
	if err := last.Undo(ctx); err != nil {
		return {{$fmt}}.Errorf("undo command: %w", err)
	}
	h.done = h.done[:len(h.done)-1]
	return nil
}`,
	},
	{
		ID: "iterator", Title: "Iterator", Group: "behavioral",
		Detail: "iter.Seq / iter.Seq2 on Go 1.23+, otherwise Next() and Value()",
		Note:   "a slice or map needs no iterator: range over it, or use slices.Values and maps.All;\nwrite one only for a collection with its own traversal.",
		Params: []ParamSpec{
			{Key: "type", Label: "Collection", Kind: kindType, Default: []string{"Collection"}},
			{Key: "element", Label: "Element type", Kind: kindTypeExpr, Default: []string{"string"}},
		},
		Tmpl: `{{.header}}

// {{.type}} holds a sequence of {{.element}} values.
type {{.type}} struct {
	items []{{.element}}
}

// Add appends item.
func ({{recv .type}} *{{.type}}) Add(item {{.element}}) {
	{{recv .type}}.items = append({{recv .type}}.items, item)
}
{{if .modern}}
// Values returns an iterator over the items, for use with range.
func ({{recv .type}} *{{.type}}) Values() {{pkg "iter"}}.Seq[{{.element}}] {
	return func(yield func({{.element}}) bool) {
		for _, item := range {{recv .type}}.items {
			if !yield(item) {
				return
			}
		}
	}
}

// All returns an iterator over index and item pairs, for use with range.
func ({{recv .type}} *{{.type}}) All() {{pkg "iter"}}.Seq2[int, {{.element}}] {
	return func(yield func(int, {{.element}}) bool) {
		for index, item := range {{recv .type}}.items {
			if !yield(index, item) {
				return
			}
		}
	}
}
{{else}}
// Iterator returns an iterator positioned before the first item.
func ({{recv .type}} *{{.type}}) Iterator() *{{.type}}Iterator {
	return &{{.type}}Iterator{items: {{recv .type}}.items, pos: -1}
}

// {{.type}}Iterator walks a {{.type}}: call Next, then Value.
type {{.type}}Iterator struct {
	items []{{.element}}
	pos   int
}

// Next moves to the next item and reports whether there is one.
func (it *{{.type}}Iterator) Next() bool {
	if it.pos+1 >= len(it.items) {
		return false
	}
	it.pos++
	return true
}

// Value returns the current item; call it only after Next reported true.
func (it *{{.type}}Iterator) Value() {{.element}} { return it.items[it.pos] }
{{end}}`,
	},
	{
		ID: "mediator", Title: "Mediator", Group: "behavioral",
		Detail: "a mediator interface; colleagues talk to it, never to each other",
		Params: []ParamSpec{
			{Key: "mediator", Label: "Mediator interface", Kind: kindType, Default: []string{"Mediator"}},
			{Key: "hub", Label: "Mediator implementation", Kind: kindType, Default: []string{"Hub"}},
			{Key: "colleague", Label: "Colleague", Kind: kindType, Default: []string{"Participant"}},
		},
		Tmpl: `{{.header}}

// {{.mediator}} coordinates colleagues so that they never refer to each other.
type {{.mediator}} interface {
	Notify(from, event string)
}

// {{.hub}} passes every event to all colleagues except the sender. It is not safe for concurrent use.
type {{.hub}} struct {
	colleagues []*{{.colleague}}
}

var _ {{.mediator}} = (*{{.hub}})(nil)

// Register adds c to the hub and points it at the hub.
func ({{recv .hub}} *{{.hub}}) Register(c *{{.colleague}}) {
	c.mediator = {{recv .hub}}
	{{recv .hub}}.colleagues = append({{recv .hub}}.colleagues, c)
}

// Notify delivers event to every colleague other than from.
func ({{recv .hub}} *{{.hub}}) Notify(from, event string) {
	for _, c := range {{recv .hub}}.colleagues {
		if c.name != from && c.on != nil {
			c.on(from, event)
		}
	}
}

// {{.colleague}} sends events through its {{.mediator}} and receives the ones others send.
type {{.colleague}} struct {
	name     string
	mediator {{.mediator}}
	on       func(from, event string)
}

// New{{.colleague}} returns a {{.colleague}} that calls on for each event it receives.
func New{{.colleague}}(name string, on func(from, event string)) *{{.colleague}} {
	return &{{.colleague}}{name: name, on: on}
}

// Send hands event to the mediator; it does nothing before the colleague is registered.
func ({{recv .colleague}} *{{.colleague}}) Send(event string) {
	if {{recv .colleague}}.mediator != nil {
		{{recv .colleague}}.mediator.Notify({{recv .colleague}}.name, event)
	}
}`,
	},
	{
		ID: "memento", Title: "Memento", Group: "behavioral",
		Detail: "Snapshot() and Restore() around an unexported state type",
		Params: []ParamSpec{
			{Key: "type", Label: "Originator", Kind: kindType, Default: []string{"Editor"}},
			{Key: "fields", Label: "State (name type)", Kind: kindFields, Multi: true, Default: []string{"text string", "cursor int"}},
		},
		Tmpl: `{{.header}}

// {{.type}} is the object whose state can be saved and restored.
type {{.type}} struct {
	{{local .type}}State
}

// {{local .type}}State is the part of a {{.type}} that a snapshot keeps. It is unexported so only this package can look inside a snapshot.
type {{local .type}}State struct {
{{- range .fields}}
	{{.Name}} {{.Type}}
{{- end}}
}

// {{.type}}Snapshot is an opaque copy of a {{.type}}'s state.
type {{.type}}Snapshot struct {
	state {{local .type}}State
}

// Snapshot captures the current state. Slices and maps in the state are shared, not copied: clone them here if they change in place.
func ({{.r}} *{{.type}}) Snapshot() {{.type}}Snapshot {
	return {{.type}}Snapshot{state: {{.r}}.{{local .type}}State}
}

// Restore returns {{.r}} to a state captured by Snapshot.
func ({{.r}} *{{.type}}) Restore(snapshot {{.type}}Snapshot) {
	{{.r}}.{{local .type}}State = snapshot.state
}`,
	},
	{
		ID: "observer", Title: "Observer", Group: "behavioral",
		Detail: "Subscribe returns an unsubscribe func; Notify calls subscribers without goroutines",
		Params: []ParamSpec{
			{Key: "subject", Label: "Subject", Kind: kindType, Default: []string{"Topic"}},
			{Key: "event", Label: "Event type", Kind: kindTypeExpr, Default: []string{"string"}},
		},
		Tmpl: `{{.header}}
{{$r := recv .subject}}
// {{.subject}} delivers events to its subscribers. It starts no goroutines, so there is nothing to leak: subscribers run on the
// goroutine that calls Notify, and the function Subscribe returns removes them. It is safe for concurrent use.
type {{.subject}} struct {
	mu   {{pkg "sync"}}.Mutex
	next int
	subs []{{local .subject}}Sub
}

type {{local .subject}}Sub struct {
	id int
	fn func(event {{.event}})
}

// Subscribe registers fn and returns the function that removes it again.
func ({{$r}} *{{.subject}}) Subscribe(fn func(event {{.event}})) (unsubscribe func()) {
	{{$r}}.mu.Lock()
	defer {{$r}}.mu.Unlock()
	{{$r}}.next++
	id := {{$r}}.next
	{{$r}}.subs = append({{$r}}.subs, {{local .subject}}Sub{id: id, fn: fn})
	return func() {
		{{$r}}.mu.Lock()
		defer {{$r}}.mu.Unlock()
		for index, sub := range {{$r}}.subs {
			if sub.id == id {
				{{$r}}.subs = append({{$r}}.subs[:index:index], {{$r}}.subs[index+1:]...)
				return
			}
		}
	}
}

// Notify calls every current subscriber with event, in subscription order. Subscribers may unsubscribe while they run.
func ({{$r}} *{{.subject}}) Notify(event {{.event}}) {
	{{$r}}.mu.Lock()
	subs := append([]{{local .subject}}Sub(nil), {{$r}}.subs...)
	{{$r}}.mu.Unlock()
	for _, sub := range subs {
		sub.fn(event)
	}
}`,
	},
	{
		ID: "state", Title: "State", Group: "behavioral",
		Detail: "a state interface; the context delegates to its current state",
		Params: []ParamSpec{
			{Key: "context", Label: "Context", Kind: kindType, Default: []string{"Door"}},
			{Key: "states", Label: "States (each moves on to the next)", Kind: kindNames, Multi: true, Default: []string{"Open", "Closed"}},
		},
		Tmpl: `{{.header}}

// {{.context}}State is one state of a {{.context}}: it does the work for that state and moves the {{.context}} on.
type {{.context}}State interface {
	// Name identifies the state.
	Name() string
	// Advance does the state's work and sets the next state on machine.
	Advance(machine *{{.context}})
}

// {{.context}} delegates its behaviour to its current state.
type {{.context}} struct {
	state {{.context}}State
}

// New{{.context}} returns a {{.context}} in its first state.
func New{{.context}}() *{{.context}} {
	return &{{.context}}{state: {{index .states 0}}State{}}
}

// State returns the name of the current state.
func ({{recv .context}} *{{.context}}) State() string { return {{recv .context}}.state.Name() }

// Advance runs the current state.
func ({{recv .context}} *{{.context}}) Advance() { {{recv .context}}.state.Advance({{recv .context}}) }
{{range $i, $s := .states}}
// {{$s}}State is the {{lower $s}} state.
type {{$s}}State struct{}

// Name implements {{$.context}}State.
func ({{$s}}State) Name() string { return "{{lower $s}}" }

// Advance implements {{$.context}}State; the next state is {{nextOf $.states $i}}.
func ({{$s}}State) Advance(machine *{{$.context}}) { machine.state = {{nextOf $.states $i}}State{} }
{{end}}`,
	},
	{
		ID: "strategy", Title: "Strategy", Group: "behavioral",
		Detail: "a one-method interface, strategies injected through the constructor",
		Note:   "with a single method a func type does the same with less code: type Strategy func(...).",
		Params: []ParamSpec{
			{Key: "strategy", Label: "Strategy interface", Kind: kindType, Default: []string{"Strategy"}},
			{Key: "method", Label: "Method signature", Kind: kindSignature,
				Default: []string{"Execute(ctx context.Context, input string) (string, error)"}},
			{Key: "strategies", Label: "Strategy names", Kind: kindNames, Multi: true, Default: []string{"Fast", "Safe"}},
			{Key: "user", Label: "Type that uses a strategy", Kind: kindType, Default: []string{"Runner"}},
		},
		Tmpl: `{{.header}}

// {{.strategy}} is one interchangeable algorithm.
type {{.strategy}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}
{{range .strategies}}
// {{.}} is one {{$.strategy}}.
type {{.}} struct{}

{{stub . $.strategy $.method}}
{{end}}
// {{.user}} runs the {{.strategy}} it was given.
type {{.user}} struct {
	strategy {{.strategy}}
}

// New{{.user}} returns a {{.user}} that uses strategy.
func New{{.user}}(strategy {{.strategy}}) *{{.user}} {
	return &{{.user}}{strategy: strategy}
}

// {{.method.Name}} delegates to the strategy.
func ({{recvSig .user .method}} *{{.user}}) {{.method.Name}}({{.method.Params}}) {{.method.Results}} {
	{{.method.Ret}}{{recvSig .user .method}}.strategy.{{.method.Name}}({{.method.Args}})
}`,
	},
	{
		ID: "template-method", Title: "Template Method", Group: "behavioral",
		Detail:   "a struct of step funcs and a Run() that fixes their order",
		Reserved: map[string][]string{"steps": {"Run"}},
		Params: []ParamSpec{
			{Key: "type", Label: "Type", Kind: kindType, Default: []string{"Job"}},
			{Key: "steps", Label: "Steps (in order)", Kind: kindNames, Multi: true, Default: []string{"Open", "Process", "Close"}},
		},
		Tmpl: `{{.header}}
{{$ctx := pkg "context"}}{{$fmt := pkg "fmt"}}
// {{.type}} fixes the order of its steps; callers supply the steps as functions, and a nil step is skipped.
type {{.type}} struct {
{{- range .steps}}
	{{.}} func(ctx {{$ctx}}.Context) error
{{- end}}
}

// Run executes the steps in order and stops at the first error.
func ({{recv .type}} *{{.type}}) Run(ctx {{$ctx}}.Context) error {
	steps := []struct {
		name string
		run  func({{$ctx}}.Context) error
	}{
{{- range .steps}}
		{"{{lower .}}", {{recv $.type}}.{{.}}},
{{- end}}
	}
	for _, step := range steps {
		if step.run == nil {
			continue
		}
		if err := step.run(ctx); err != nil {
			return {{$fmt}}.Errorf("%s: %w", step.name, err)
		}
	}
	return nil
}`,
	},
	{
		ID: "visitor", Title: "Visitor", Group: "behavioral",
		Detail: "Accept(Visitor) on each element and a visitor interface with one method per element",
		Params: []ParamSpec{
			{Key: "element", Label: "Element interface", Kind: kindType, Default: []string{"Node"}},
			{Key: "visitor", Label: "Visitor interface", Kind: kindType, Default: []string{"Visitor"}},
			{Key: "elements", Label: "Concrete elements", Kind: kindNames, Multi: true, Default: []string{"Number", "Add"}},
		},
		Tmpl: `{{.header}}

// {{.element}} is something a {{.visitor}} can visit.
type {{.element}} interface {
	Accept(visitor {{.visitor}})
}

// {{.visitor}} has one method per concrete {{.element}}. For a closed set of types a type switch is often simpler.
type {{.visitor}} interface {
{{- range .elements}}
	Visit{{.}}(*{{.}})
{{- end}}
}
{{range .elements}}
// {{.}} is a {{$.element}}.
type {{.}} struct{}

// Accept calls the visitor's method for {{.}}.
func ({{recv .}} *{{.}}) Accept(visitor {{$.visitor}}) { visitor.Visit{{.}}({{recv .}}) }
{{end}}`,
	},
}
