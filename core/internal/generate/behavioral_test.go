package generate

func behavioralCases() []patternCase {
	return []patternCase{
		{name: "chain-of-responsibility", id: "chain-of-responsibility", example: `import (
	"context"
	"testing"
)

func TestChain(t *testing.T) {
	is := func(want string) Handler {
		return HandlerFunc(func(_ context.Context, req string) bool { return req == want })
	}
	chain := HandlerChain{is("a"), is("b")}
	ctx := context.Background()
	if !chain.Handle(ctx, "b") || chain.Handle(ctx, "c") {
		t.Error("a request is handled by the first link that takes it, and falls off the end otherwise")
	}
}
`},
		{name: "command", id: "command", example: `import (
	"context"
	"errors"
	"testing"
)

type counter struct{ n, fail int }

func (c *counter) Execute(context.Context) error {
	if c.fail > 0 {
		return errors.New("boom")
	}
	c.n++
	return nil
}
func (c *counter) Undo(context.Context) error { c.n--; return nil }

func TestCommand(t *testing.T) {
	ctx := context.Background()
	var history CommandHistory
	c := &counter{}
	if err := history.Do(ctx, c); err != nil || c.n != 1 {
		t.Fatalf("do: %v %d", err, c.n)
	}
	if err := history.Undo(ctx); err != nil || c.n != 0 {
		t.Fatalf("undo: %v %d", err, c.n)
	}
	if err := history.Undo(ctx); err != nil {
		t.Fatal("an empty history has nothing to undo")
	}
	bad := &counter{fail: 1}
	if err := history.Do(ctx, bad); err == nil || err.Error() != "execute command: boom" {
		t.Errorf("err = %v", err)
	}
	if err := history.Undo(ctx); err != nil || bad.n != 0 {
		t.Error("a failed command is not recorded")
	}
}
`},
		{name: "iterator", id: "iterator", example: `import "testing"

func TestIteratorNextValue(t *testing.T) {
	var c Collection
	c.Add("a")
	c.Add("b")
	var got []string
	for it := c.Iterator(); it.Next(); {
		got = append(got, it.Value())
	}
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Errorf("got %v", got)
	}
	if (&Collection{}).Iterator().Next() {
		t.Error("an empty collection has no items")
	}
}
`},
		{name: "iterator-modern", id: "iterator", goVersion: "1.23", example: `import "testing"

func TestIteratorSeq(t *testing.T) {
	var c Collection
	c.Add("a")
	c.Add("b")
	c.Add("c")
	var got []string
	for v := range c.Values() {
		if v == "c" {
			break
		}
		got = append(got, v)
	}
	if len(got) != 2 {
		t.Errorf("got %v", got)
	}
	for i, v := range c.All() {
		if i == 1 && v != "b" {
			t.Errorf("All gave %d, %q", i, v)
		}
	}
}
`},
		{name: "mediator", id: "mediator", example: `import "testing"

func TestMediator(t *testing.T) {
	var hub Hub
	var gotA, gotB []string
	a := NewParticipant("a", func(from, event string) { gotA = append(gotA, from+":"+event) })
	b := NewParticipant("b", func(from, event string) { gotB = append(gotB, from+":"+event) })
	hub.Register(a)
	hub.Register(b)
	a.Send("hello")
	if len(gotA) != 0 || len(gotB) != 1 || gotB[0] != "a:hello" {
		t.Errorf("a got %v, b got %v", gotA, gotB)
	}
	NewParticipant("lonely", nil).Send("ignored")
}
`},
		{name: "memento", id: "memento", example: `import "testing"

func TestMemento(t *testing.T) {
	e := &Editor{}
	e.text = "a"
	snapshot := e.Snapshot()
	e.text, e.cursor = "b", 3
	e.Restore(snapshot)
	if e.text != "a" || e.cursor != 0 {
		t.Errorf("got %+v", e)
	}
}
`},
		{name: "observer", id: "observer", example: `import (
	"runtime"
	"testing"
)

func TestObserver(t *testing.T) {
	before := runtime.NumGoroutine()
	var topic Topic
	var got []string
	unsubscribe := topic.Subscribe(func(event string) { got = append(got, event) })
	topic.Notify("a")
	unsubscribe()
	unsubscribe()
	topic.Notify("b")
	if len(got) != 1 || got[0] != "a" {
		t.Errorf("got %v", got)
	}
	if runtime.NumGoroutine() > before {
		t.Error("the topic must not start goroutines")
	}
}

func TestObserverMayUnsubscribeWhileNotified(t *testing.T) {
	var topic Topic
	var unsubscribe func()
	calls := 0
	unsubscribe = topic.Subscribe(func(string) { calls++; unsubscribe() })
	topic.Notify("a")
	topic.Notify("b")
	if calls != 1 {
		t.Errorf("calls = %d", calls)
	}
}
`},
		{name: "state", id: "state", example: `import "testing"

func TestState(t *testing.T) {
	d := NewDoor()
	var names []string
	for range 3 {
		names = append(names, d.State())
		d.Advance()
	}
	if names[0] != "open" || names[1] != "closed" || names[2] != "open" {
		t.Errorf("got %v", names)
	}
}
`},
		{name: "strategy", id: "strategy", example: `import (
	"context"
	"testing"
)

func TestStrategy(t *testing.T) {
	for _, s := range []Strategy{&Fast{}, &Safe{}} {
		if _, err := NewRunner(s).Execute(context.Background(), "x"); err != nil {
			t.Fatal(err)
		}
	}
}
`},
		{name: "strategy-custom", id: "strategy", values: []ParamValue{
			{Key: "strategy", Values: []string{"Pricing"}},
			{Key: "method", Values: []string{"Price(items ...string) float64"}},
			{Key: "strategies", Values: []string{"Flat", "Tiered"}},
			{Key: "user", Values: []string{"Cart"}},
		}, example: `import "testing"

func TestStrategyCustom(t *testing.T) {
	if NewCart(&Tiered{}).Price("a", "b") != 0 {
		t.Error("the stub prices nothing")
	}
}
`},
		{name: "template-method", id: "template-method", example: `import (
	"context"
	"errors"
	"testing"
)

func TestTemplateMethod(t *testing.T) {
	var order []string
	step := func(name string) func(context.Context) error {
		return func(context.Context) error { order = append(order, name); return nil }
	}
	job := &Job{Open: step("open"), Close: step("close")}
	if err := job.Run(context.Background()); err != nil || len(order) != 2 || order[1] != "close" {
		t.Fatalf("order %v err %v", order, err)
	}
	boom := errors.New("boom")
	job.Process = func(context.Context) error { return boom }
	err := job.Run(context.Background())
	if !errors.Is(err, boom) || err.Error() != "process: boom" {
		t.Errorf("err = %v", err)
	}
}
`},
		{name: "visitor", id: "visitor", example: `import "testing"

type counter struct{ numbers, adds int }

func (c *counter) VisitNumber(*Number) { c.numbers++ }
func (c *counter) VisitAdd(*Add)       { c.adds++ }

func TestVisitor(t *testing.T) {
	var c counter
	for _, n := range []Node{&Number{}, &Add{}, &Number{}} {
		n.Accept(&c)
	}
	if c.numbers != 2 || c.adds != 1 {
		t.Errorf("got %+v", c)
	}
}
`},
	}
}
