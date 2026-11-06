package generate

// The creational patterns: object creation without scattering constructors through the code.
var creational = []patternDef{
	{
		ID: "factory-method", Title: "Factory Method", Group: "creational",
		Detail: "NewShape(kind) returning an interface, from a registry of constructors",
		Params: []ParamSpec{
			{Key: "product", Label: "Product interface", Kind: kindType, Default: []string{"Shape"}},
			{Key: "method", Label: "Product method", Kind: kindSignature, Default: []string{"Area() float64"}},
			{Key: "kinds", Label: "Concrete products", Kind: kindNames, Multi: true, Default: []string{"Circle", "Square"}},
		},
		Tmpl: `{{.header}}

// {{.product}} is what the factory creates.
type {{.product}} interface {
	{{.method.Name}}({{.method.Params}}) {{.method.Results}}
}
{{range .kinds}}
// {{.}} is one kind of {{$.product}}.
type {{.}} struct{}

{{stub . $.product $.method}}
{{end}}
// {{local .product}}Factories maps a kind to the function that creates it; add one line per new product.
var {{local .product}}Factories = map[string]func() {{.product}}{
{{- range .kinds}}
	"{{lower .}}": func() {{$.product}} { return &{{.}}{} },
{{- end}}
}

// New{{.product}} returns the {{.product}} registered under kind.
func New{{.product}}(kind string) ({{.product}}, error) {
	create, ok := {{local .product}}Factories[kind]
	if !ok {
		return nil, {{pkg "fmt"}}.Errorf("unknown {{lower .product}} kind %q", kind)
	}
	return create(), nil
}`,
	},
	{
		ID: "abstract-factory", Title: "Abstract Factory", Group: "creational",
		Detail: "an interface of constructors and one struct per product family",
		Params: []ParamSpec{
			{Key: "factory", Label: "Factory interface", Kind: kindType, Default: []string{"WidgetFactory"}},
			{Key: "products", Label: "Products", Kind: kindNames, Multi: true, Default: []string{"Button", "Checkbox"}},
			{Key: "families", Label: "Families", Kind: kindNames, Multi: true, Default: []string{"Light", "Dark"}},
		},
		Tmpl: `{{.header}}
{{$fmt := pkg "fmt"}}
{{range .products}}// {{.}} is one product of every family.
type {{.}} interface{ {{$fmt}}.Stringer }

{{end}}// {{.factory}} creates the products of one family.
type {{.factory}} interface {
{{- range .products}}
	New{{.}}() {{.}}
{{- end}}
}
{{range $family := .families}}
// {{$family}}Factory creates the {{$family}} family.
type {{$family}}Factory struct{}

var _ {{$.factory}} = {{$family}}Factory{}
{{range $.products}}
// {{$family}}{{.}} is the {{$family}} family's {{.}}.
type {{$family}}{{.}} struct{}

// String implements fmt.Stringer.
func ({{$family}}{{.}}) String() string { return "{{lower $family}} {{lower .}}" }

// New{{.}} returns a {{$family}}{{.}}.
func ({{$family}}Factory) New{{.}}() {{.}} { return {{$family}}{{.}}{} }
{{end}}{{end}}`,
	},
	{
		ID: "builder", Title: "Builder", Group: "creational",
		Detail: "functional options: Option funcs and NewServer(opts ...)",
		Params: []ParamSpec{
			{Key: "type", Label: "Type to build", Kind: kindType, Default: []string{"Server"}},
			{Key: "fields", Label: "Fields (name type)", Kind: kindFields, Multi: true, Default: []string{"addr string", "port int"}},
		},
		Tmpl: `{{.header}}

// {{.type}} is built with functional options; fields left unset keep their zero value.
type {{.type}} struct {
{{- range .fields}}
	{{.Name}} {{.Type}}
{{- end}}
}

// {{.type}}Option configures a {{.type}}.
type {{.type}}Option func(*{{.type}})
{{range .fields}}
// With{{.Export}} sets the {{.Name}} field.
func With{{.Export}}({{.Param}} {{.Type}}) {{$.type}}Option {
	return func({{$.r}} *{{$.type}}) { {{$.r}}.{{.Name}} = {{.Param}} }
}
{{end}}
// New{{.type}} returns a {{.type}} with opts applied in order; set defaults before the loop.
func New{{.type}}(opts ...{{.type}}Option) *{{.type}} {
	{{.r}} := &{{.type}}{}
	for _, opt := range opts {
		opt({{.r}})
	}
	return {{.r}}
}`,
	},
	{
		ID: "prototype", Title: "Prototype", Group: "creational",
		Detail: "a Clone() method that deep-copies slices and maps",
		Params: []ParamSpec{
			{Key: "type", Label: "Type to clone", Kind: kindType, Default: []string{"Document"}},
			{Key: "fields", Label: "Fields (name type)", Kind: kindFields, Multi: true,
				Default: []string{"title string", "tags []string", "meta map[string]int"}},
		},
		Tmpl: `{{.header}}

// {{.type}} can produce independent copies of itself.
type {{.type}} struct {
{{- range .fields}}
	{{.Name}} {{.Type}}
{{- end}}
}

// Clone returns a copy that shares no slice or map with {{.r}}. Pointer fields are still shared: clone them here too if they must not be.
func ({{.r}} *{{.type}}) Clone() *{{.type}} {
	clone := *{{.r}}
{{- range .fields}}
{{- if isSlice .Type}}
	clone.{{.Name}} = append({{.Type}}(nil), {{$.r}}.{{.Name}}...)
{{- else if isMap .Type}}
	clone.{{.Name}} = {{pkg "maps"}}.Clone({{$.r}}.{{.Name}})
{{- end}}
{{- end}}
	return &clone
}`,
	},
	{
		ID: "singleton", Title: "Singleton", Group: "creational",
		Detail: "a package-level value created once behind sync.Once, read through Instance()",
		Note:   "pass a *Config to the code that needs it, or use a plain package variable;\na Singleton is global state and makes tests and reuse harder.",
		Params: []ParamSpec{
			{Key: "type", Label: "Type", Kind: kindType, Default: []string{"Config"}},
		},
		Tmpl: `{{.header}}

// {{.type}} is the one shared value.
type {{.type}} struct{}

var (
	{{local .type}}Once     {{pkg "sync"}}.Once
	{{local .type}}Instance *{{.type}}
)

// Instance returns the shared {{.type}}, creating it on first use. It is safe for concurrent use.
func Instance() *{{.type}} {
	{{local .type}}Once.Do(func() {
		{{local .type}}Instance = &{{.type}}{}
	})
	return {{local .type}}Instance
}`,
	},
}
