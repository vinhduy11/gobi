package generate

// The structural patterns: how types are put together.
var structural = []patternDef{
	{
		ID: "adapter", Title: "Adapter", Group: "structural",
		Detail: "a struct embedding the adaptee and implementing the target interface",
		Params: []ParamSpec{
			{Key: "target", Label: "Target interface", Kind: kindType, Default: []string{"Printer"}},
			{Key: "method", Label: "Target method", Kind: kindSignature, Default: []string{"Print(text string) error"}},
			{Key: "adaptee", Label: "Adaptee type", Kind: kindType, Default: []string{"LegacyPrinter"}},
		},
		Tmpl: `{{.header}}

// {{.target}} is the interface the client code expects.
type {{.target}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}
{{if not (index .declared .adaptee)}}
// {{.adaptee}} stands in for the existing type being adapted; replace it with yours.
type {{.adaptee}} struct{}
{{end}}
// {{.adaptee}}Adapter makes a *{{.adaptee}} satisfy {{.target}}.
type {{.adaptee}}Adapter struct {
	*{{.adaptee}}
}

var _ {{.target}} = (*{{.adaptee}}Adapter)(nil)

// New{{.adaptee}}Adapter wraps adaptee.
func New{{.adaptee}}Adapter(adaptee *{{.adaptee}}) *{{.adaptee}}Adapter {
	return &{{.adaptee}}Adapter{ {{.adaptee}}: adaptee }
}

{{stub (printf "%sAdapter" .adaptee) .target .method}}`,
	},
	{
		ID: "bridge", Title: "Bridge", Group: "structural",
		Detail: "an abstraction struct holding an implementor interface",
		Params: []ParamSpec{
			{Key: "abstraction", Label: "Abstraction", Kind: kindType, Default: []string{"Message"}},
			{Key: "implementor", Label: "Implementor interface", Kind: kindType, Default: []string{"Sender"}},
			{Key: "method", Label: "Implementor method", Kind: kindSignature, Default: []string{"Send(text string) error"}},
			{Key: "implementations", Label: "Implementations", Kind: kindNames, Multi: true, Default: []string{"Email", "Push"}},
		},
		Tmpl: `{{.header}}

// {{.implementor}} is the implementation side; abstractions hold one and call it.
type {{.implementor}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}
{{range .implementations}}
// {{.}}{{$.implementor}} is one {{$.implementor}}.
type {{.}}{{$.implementor}} struct{}

{{stub (printf "%s%s" . $.implementor) $.implementor $.method}}
{{end}}
// {{.abstraction}} is the abstraction side; it delegates the work to its {{.implementor}}.
type {{.abstraction}} struct {
	impl {{.implementor}}
}

// New{{.abstraction}} returns a {{.abstraction}} that uses impl.
func New{{.abstraction}}(impl {{.implementor}}) *{{.abstraction}} {
	return &{{.abstraction}}{impl: impl}
}

// {{.method.Name}} forwards to the implementation.
func ({{recvSig .abstraction .method}} *{{.abstraction}}) {{.method.Name}}({{.method.Params}}) {{.method.Results}} {
	{{.method.Ret}}{{recvSig .abstraction .method}}.impl.{{.method.Name}}({{.method.Args}})
}`,
	},
	{
		ID: "composite", Title: "Composite", Group: "structural",
		Detail: "an interface implemented by leaves and by a node holding []Component",
		Params: []ParamSpec{
			{Key: "component", Label: "Component interface", Kind: kindType, Default: []string{"Node"}},
			{Key: "method", Label: "Component method", Kind: kindSignature, Default: []string{"Size() int"}},
			{Key: "leaf", Label: "Leaf", Kind: kindType, Default: []string{"File"}},
			{Key: "composite", Label: "Composite", Kind: kindType, Default: []string{"Dir"}},
		},
		Tmpl: `{{.header}}

// {{.component}} is implemented by leaves and composites alike, so callers treat both the same.
type {{.component}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}

// {{.leaf}} is a {{.component}} without children.
type {{.leaf}} struct{}

{{stub .leaf .component .method}}

// {{.composite}} is a {{.component}} made of other components.
type {{.composite}} struct {
	children []{{.component}}
}

// Add appends children to the composite.
func ({{recvSig .composite .method}} *{{.composite}}) Add(children ...{{.component}}) {
	{{recvSig .composite .method}}.children = append({{recvSig .composite .method}}.children, children...)
}

// {{.method.Name}} implements {{.component}} by visiting every child; combine their results as the operation needs.
func ({{recvSig .composite .method}} *{{.composite}}) {{.method.Name}}({{.method.Params}}) {{.method.Stub}} {
	for _, member := range {{recvSig .composite .method}}.children {
		member.{{.method.Name}}({{.method.Args}})
	}
{{- if .method.Stub}}
	return
{{- end}}
}`,
	},
	{
		ID: "decorator", Title: "Decorator", Group: "structural",
		Detail: "func(Handler) Handler middleware and a Decorate helper",
		Note:   "for one method, a func type plus func(Handler) Handler middleware is all a decorator needs; no wrapper struct.",
		Params: []ParamSpec{
			{Key: "component", Label: "Component interface", Kind: kindType, Default: []string{"Handler"}},
			{Key: "method", Label: "Component method", Kind: kindSignature,
				Default: []string{"Handle(ctx context.Context, input string) (string, error)"}},
		},
		Tmpl: `{{.header}}

// {{.component}} is the component that decorators wrap.
type {{.component}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}

// {{.component}}Func lets an ordinary function be a {{.component}}.
type {{.component}}Func func({{.method.Params}}) {{.method.Results}}

// {{.method.Name}} calls f.
func ({{recvSig (printf "%sFunc" .component) .method}} {{.component}}Func) {{.method.Name}}({{.method.Params}}) {{.method.Results}} {
	{{.method.Ret}}{{recvSig (printf "%sFunc" .component) .method}}({{.method.Args}})
}

// {{.component}}Decorator wraps a {{.component}} to add behaviour before or after it.
type {{.component}}Decorator func({{.component}}) {{.component}}

// Decorate{{.component}} applies the decorators to c; the first one listed ends up outermost.
func Decorate{{.component}}(c {{.component}}, decorators ...{{.component}}Decorator) {{.component}} {
	for i := len(decorators) - 1; i >= 0; i-- {
		c = decorators[i](c)
	}
	return c
}`,
	},
	{
		ID: "facade", Title: "Facade", Group: "structural",
		Detail: "a struct that wires subsystems behind a few methods",
		Params: []ParamSpec{
			{Key: "facade", Label: "Facade", Kind: kindType, Default: []string{"Shop"}},
			{Key: "subsystems", Label: "Subsystems", Kind: kindNames, Multi: true, Default: []string{"Inventory", "Payment", "Shipping"}},
			{Key: "operations", Label: "Operations", Kind: kindNames, Multi: true, Default: []string{"Checkout"}},
		},
		Tmpl: `{{.header}}
{{range .subsystems}}{{if not (index $.declared .)}}
// {{.}} is one subsystem behind the facade; replace it with the real one.
type {{.}} struct{}
{{end}}{{end}}
// {{.facade}} offers a few simple methods over several subsystems.
type {{.facade}} struct {
{{- range .subsystems}}
	{{local .}} *{{.}}
{{- end}}
}

// New{{.facade}} wires the subsystems together.
func New{{.facade}}(
{{- range $i, $s := .subsystems}}{{if $i}}, {{end}}{{local $s}} *{{$s}}{{end}}) *{{.facade}} {
	return &{{.facade}}{
{{- range .subsystems}}
		{{local .}}: {{local .}},
{{- end}}
	}
}
{{range .operations}}
// {{.}} coordinates the subsystems for one use case.
func ({{recv $.facade}} *{{$.facade}}) {{.}}(ctx {{pkg "context"}}.Context) error {
	// TODO: call the subsystems in order and wrap their errors with %w.
	return nil
}
{{end}}`,
	},
	{
		ID: "flyweight", Title: "Flyweight", Group: "structural",
		Detail: "shared immutable values handed out from a mutex-guarded map",
		Params: []ParamSpec{
			{Key: "type", Label: "Shared value", Kind: kindType, Default: []string{"Glyph"}},
			{Key: "fields", Label: "Fields (name type, comparable)", Kind: kindFields, Multi: true,
				Default: []string{"char rune", "font string"}},
		},
		Tmpl: `{{.header}}

// {{.type}} is the shared, immutable state. Every field must be comparable: the value itself is the pool key.
type {{.type}} struct {
{{- range .fields}}
	{{.Name}} {{.Type}}
{{- end}}
}

// {{.type}}Pool hands out one shared *{{.type}} per distinct value. It is safe for concurrent use.
type {{.type}}Pool struct {
	mu    {{pkg "sync"}}.Mutex
	items map[{{.type}}]*{{.type}}
}

// New{{.type}}Pool returns an empty pool.
func New{{.type}}Pool() *{{.type}}Pool {
	return &{{.type}}Pool{items: make(map[{{.type}}]*{{.type}})}
}

// Get returns the shared {{.type}} equal to v, creating it on first use.
func ({{recv (printf "%sPool" .type)}} *{{.type}}Pool) Get(v {{.type}}) *{{.type}} {
	{{recv (printf "%sPool" .type)}}.mu.Lock()
	defer {{recv (printf "%sPool" .type)}}.mu.Unlock()
	if shared, ok := {{recv (printf "%sPool" .type)}}.items[v]; ok {
		return shared
	}
	{{recv (printf "%sPool" .type)}}.items[v] = &v
	return &v
}`,
	},
	{
		ID: "proxy", Title: "Proxy", Group: "structural",
		Detail: "a struct with the subject's interface that creates the real one lazily",
		Params: []ParamSpec{
			{Key: "subject", Label: "Subject interface", Kind: kindType, Default: []string{"Service"}},
			{Key: "method", Label: "Subject method", Kind: kindSignature,
				Default: []string{"Fetch(ctx context.Context, key string) (string, error)"}},
		},
		Tmpl: `{{.header}}

// {{.subject}} is implemented by the real subject and by its proxy.
type {{.subject}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}

// {{.subject}}Proxy creates the real {{.subject}} on first use and forwards to it. Add caching or an access check in the forwarding method.
type {{.subject}}Proxy struct {
	once   {{pkg "sync"}}.Once
	load   func() {{.subject}}
	target {{.subject}}
}

var _ {{.subject}} = (*{{.subject}}Proxy)(nil)

// New{{.subject}}Proxy returns a proxy that calls load once, when the real subject is first needed.
func New{{.subject}}Proxy(load func() {{.subject}}) *{{.subject}}Proxy {
	return &{{.subject}}Proxy{load: load}
}

// {{.method.Name}} forwards to the real subject.
func ({{recvSig (printf "%sProxy" .subject) .method}} *{{.subject}}Proxy) {{.method.Name}}({{.method.Params}}) {{.method.Results}} {
	{{recvSig (printf "%sProxy" .subject) .method}}.once.Do(func() { {{recvSig (printf "%sProxy" .subject) .method}}.target = {{recvSig (printf "%sProxy" .subject) .method}}.load() })
	{{.method.Ret}}{{recvSig (printf "%sProxy" .subject) .method}}.target.{{.method.Name}}({{.method.Args}})
}`,
	},
}
