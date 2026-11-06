package generate

func creationalCases() []patternCase {
	return []patternCase{
		{name: "factory-method", id: "factory-method", example: `import "testing"

func TestFactoryMethod(t *testing.T) {
	circle, err := NewShape("circle")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := circle.(*Circle); !ok {
		t.Errorf("circle is %T", circle)
	}
	if square, err := NewShape("square"); err != nil || square.Area() != 0 {
		t.Errorf("square %v %v", square, err)
	}
	if _, err := NewShape("hexagon"); err == nil {
		t.Error("an unknown kind must fail")
	}
}
`},
		{name: "abstract-factory", id: "abstract-factory", example: `import "testing"

func TestAbstractFactory(t *testing.T) {
	var factory WidgetFactory = LightFactory{}
	if got := factory.NewButton().String(); got != "light button" {
		t.Errorf("got %q", got)
	}
	if got := (DarkFactory{}).NewCheckbox().String(); got != "dark checkbox" {
		t.Errorf("got %q", got)
	}
}
`},
		{name: "builder", id: "builder", example: `import "testing"

func TestBuilder(t *testing.T) {
	s := NewServer(WithAddr("localhost:1"), WithPort(9))
	if s.addr != "localhost:1" || s.port != 9 {
		t.Errorf("got %+v", s)
	}
	if NewServer().port != 0 {
		t.Error("unset options keep the zero value")
	}
}
`},
		{name: "prototype", id: "prototype", example: `import "testing"

func TestPrototype(t *testing.T) {
	original := &Document{title: "a", tags: []string{"x"}, meta: map[string]int{"k": 1}}
	clone := original.Clone()
	clone.title, clone.tags[0], clone.meta["k"] = "b", "y", 2
	if original.title != "a" || original.tags[0] != "x" || original.meta["k"] != 1 {
		t.Errorf("the original changed: %+v", original)
	}
	if (&Document{}).Clone().tags != nil {
		t.Error("a nil slice stays nil")
	}
}
`},
		{name: "singleton", id: "singleton", example: `import (
	"sync"
	"testing"
)

func TestSingleton(t *testing.T) {
	var wg sync.WaitGroup
	got := make([]*Config, 8)
	for i := range got {
		wg.Add(1)
		go func() { defer wg.Done(); got[i] = Instance() }()
	}
	wg.Wait()
	for _, c := range got {
		if c == nil || c != got[0] {
			t.Fatal("every caller must see the same value")
		}
	}
}
`},
		{name: "builder-custom", id: "builder", values: []ParamValue{
			{Key: "type", Values: []string{"client"}},
			{Key: "fields", Values: []string{"baseURL string", "timeout time.Duration", "retries int"}},
		}, example: `import (
	"testing"
	"time"
)

func TestBuilderCustom(t *testing.T) {
	c := NewClient(WithBaseURL("http://x"), WithTimeout(time.Second), WithRetries(3))
	if c.baseURL != "http://x" || c.timeout != time.Second || c.retries != 3 {
		t.Errorf("got %+v", c)
	}
}
`},
	}
}
