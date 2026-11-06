package generate

func structuralCases() []patternCase {
	return []patternCase{
		{name: "adapter", id: "adapter", example: `import "testing"

func TestAdapter(t *testing.T) {
	var p Printer = NewLegacyPrinterAdapter(&LegacyPrinter{})
	if err := p.Print("x"); err != nil {
		t.Fatal(err)
	}
}
`},
		{name: "bridge", id: "bridge", example: `import "testing"

func TestBridge(t *testing.T) {
	for _, impl := range []Sender{&EmailSender{}, &PushSender{}} {
		if err := NewMessage(impl).Send("hi"); err != nil {
			t.Fatal(err)
		}
	}
}
`},
		{name: "composite", id: "composite", example: `import "testing"

func TestComposite(t *testing.T) {
	root := &Dir{}
	root.Add(&File{}, &Dir{})
	var node Node = root
	if node.Size() != 0 || len(root.children) != 2 {
		t.Errorf("size %d children %d", node.Size(), len(root.children))
	}
}
`},
		{name: "decorator", id: "decorator", example: `import (
	"context"
	"strings"
	"testing"
)

func TestDecorator(t *testing.T) {
	upper := func(next Handler) Handler {
		return HandlerFunc(func(ctx context.Context, in string) (string, error) {
			out, err := next.Handle(ctx, in)
			return strings.ToUpper(out), err
		})
	}
	base := HandlerFunc(func(_ context.Context, in string) (string, error) { return in + "!", nil })
	got, err := DecorateHandler(base, upper).Handle(context.Background(), "hi")
	if err != nil || got != "HI!" {
		t.Errorf("got %q, %v", got, err)
	}
}
`},
		{name: "facade", id: "facade", example: `import (
	"context"
	"testing"
)

func TestFacade(t *testing.T) {
	shop := NewShop(&Inventory{}, &Payment{}, &Shipping{})
	if err := shop.Checkout(context.Background()); err != nil {
		t.Fatal(err)
	}
}
`},
		{name: "flyweight", id: "flyweight", example: `import "testing"

func TestFlyweight(t *testing.T) {
	pool := NewGlyphPool()
	a := pool.Get(Glyph{char: 'a', font: "mono"})
	if a != pool.Get(Glyph{char: 'a', font: "mono"}) {
		t.Error("equal values must share one instance")
	}
	if a == pool.Get(Glyph{char: 'b', font: "mono"}) {
		t.Error("different values must not")
	}
}
`},
		{name: "proxy", id: "proxy", example: `import (
	"context"
	"testing"
)

type realService struct{}

func (realService) Fetch(context.Context, string) (string, error) { return "v", nil }

func TestProxy(t *testing.T) {
	loads := 0
	var service Service = NewServiceProxy(func() Service { loads++; return realService{} })
	if loads != 0 {
		t.Fatal("the real subject must not be created up front")
	}
	for range 2 {
		if got, err := service.Fetch(context.Background(), "k"); err != nil || got != "v" {
			t.Fatalf("got %q, %v", got, err)
		}
	}
	if loads != 1 {
		t.Errorf("loads = %d, want 1", loads)
	}
}
`},
	}
}
