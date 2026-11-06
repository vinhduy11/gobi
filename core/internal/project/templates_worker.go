package project

// consumerTemplate is a worker loop over a one-method Source. Kafka, MQTT or RabbitMQ adapters would implement Source.
var consumerTemplate = template{
	files: map[string]string{
		"consumer.go": `package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
)

// Message is one unit of work read from a Source.
type Message struct {
	Key   string
	Value []byte
}

// Source delivers messages. Next blocks until a message is available, returns io.EOF when the source has no more
// messages and returns the context's error when ctx ends. It must be safe for concurrent use.
type Source interface {
	Next(ctx context.Context) (Message, error)
}

// Handler processes one message. A returned error is logged and the worker moves on to the next message.
type Handler func(ctx context.Context, msg Message) error

// Consume reads from source with the given number of workers and passes every message to handle. It returns when the
// source is drained or ctx ends, after all workers have finished their current message.
func Consume(ctx context.Context, source Source, handle Handler, workers int) error {
	if workers < 1 {
		return fmt.Errorf("consume: need at least one worker, got %d", workers)
	}
	failures := make(chan error, workers)
	var wg sync.WaitGroup
	for id := 0; id < workers; id++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			failures <- work(ctx, source, handle)
		}()
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		if err != nil {
			return err
		}
	}
	return nil
}

// work is the loop of one worker. It ends quietly when the source is drained or ctx is cancelled.
func work(ctx context.Context, source Source, handle Handler) error {
	for {
		msg, err := source.Next(ctx)
		if errors.Is(err, io.EOF) || errors.Is(err, context.Canceled) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read message: %w", err)
		}
		if err := handle(ctx, msg); err != nil {
			log.Printf("handle message %q: %v", msg.Key, err)
		}
	}
}
`,
		"main.go": `package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// tickSource is a stand-in Source that produces a message every second; replace it with your broker's client.
type tickSource struct {
	count int
}

// Next waits one second, then returns the next numbered message.
func (s *tickSource) Next(ctx context.Context) (Message, error) {
	select {
	case <-ctx.Done():
		return Message{}, ctx.Err()
	case <-time.After(time.Second):
	}
	s.count++
	return Message{Key: fmt.Sprint(s.count), Value: []byte("tick")}, nil
}

// logHandler is the business logic; keep it free of I/O details so a test can call it directly.
func logHandler(_ context.Context, msg Message) error {
	log.Printf("{{name}}: message %s: %s", msg.Key, msg.Value)
	return nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Println("{{name}} consuming; press Ctrl+C to stop")
	if err := Consume(ctx, &tickSource{}, logHandler, 1); err != nil {
		log.Fatalf("{{name}}: %v", err)
	}
	log.Println("{{name}} stopped")
}
`,
	},
	tests: map[string]string{
		"consumer_test.go": `package main

import (
	"context"
	"errors"
	"io"
	"sync"
	"testing"
)

// fakeSource returns its messages once each, then io.EOF.
type fakeSource struct {
	mu       sync.Mutex
	messages []Message
}

func (s *fakeSource) Next(context.Context) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.messages) == 0 {
		return Message{}, io.EOF
	}
	msg := s.messages[0]
	s.messages = s.messages[1:]
	return msg, nil
}

func TestConsumeHandlesEveryMessage(t *testing.T) {
	source := &fakeSource{messages: []Message{{Key: "a"}, {Key: "b"}, {Key: "c"}}}
	var mu sync.Mutex
	seen := map[string]bool{}
	handle := func(_ context.Context, msg Message) error {
		mu.Lock()
		defer mu.Unlock()
		seen[msg.Key] = true
		return nil
	}
	if err := Consume(context.Background(), source, handle, 2); err != nil {
		t.Fatal(err)
	}
	if len(seen) != 3 {
		t.Fatalf("handled %v, want a, b and c", seen)
	}
}

func TestConsumeKeepsGoingAfterAHandlerError(t *testing.T) {
	source := &fakeSource{messages: []Message{{Key: "bad"}, {Key: "good"}}}
	handled := 0
	handle := func(_ context.Context, msg Message) error {
		handled++
		if msg.Key == "bad" {
			return errors.New("boom")
		}
		return nil
	}
	if err := Consume(context.Background(), source, handle, 1); err != nil {
		t.Fatal(err)
	}
	if handled != 2 {
		t.Fatalf("handled %d messages, want 2", handled)
	}
}

func TestConsumeStopsWhenTheContextIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Consume(ctx, &tickSource{}, logHandler, 1); err != nil {
		t.Fatal(err)
	}
}

func TestConsumeNeedsAWorker(t *testing.T) {
	if err := Consume(context.Background(), &fakeSource{}, logHandler, 0); err == nil {
		t.Fatal("zero workers must be an error")
	}
}
`,
	},
}

// jobTemplate runs a function once, or on a ticker, until it fails or the program is interrupted.
var jobTemplate = template{
	files: map[string]string{
		"main.go": `package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// run is the work of one job execution; replace its body and pass ctx to anything that blocks.
func run(_ context.Context) error {
	log.Println("{{name}}: job ran")
	return nil
}

// schedule calls job once, or every interval when interval is positive, until ctx ends. It returns the first error of
// job; a cancelled ctx is a normal stop and returns nil.
func schedule(ctx context.Context, interval time.Duration, job func(context.Context) error) error {
	if err := job(ctx); err != nil {
		return fmt.Errorf("run job: %w", err)
	}
	if interval <= 0 {
		return nil
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := job(ctx); err != nil {
				return fmt.Errorf("run job: %w", err)
			}
		}
	}
}

func main() {
	interval := flag.Duration("every", 0, "repeat the job at this interval; 0 runs it once")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := schedule(ctx, *interval, run); err != nil {
		log.Printf("{{name}}: %v", err)
		stop()
		os.Exit(1)
	}
}
`,
	},
	tests: map[string]string{
		"main_test.go": `package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestScheduleRunsOnceWithoutAnInterval(t *testing.T) {
	calls := 0
	err := schedule(context.Background(), 0, func(context.Context) error {
		calls++
		return nil
	})
	if err != nil || calls != 1 {
		t.Fatalf("schedule = %v after %d calls, want nil after 1", err, calls)
	}
}

func TestScheduleReturnsTheJobError(t *testing.T) {
	boom := errors.New("boom")
	err := schedule(context.Background(), 0, func(context.Context) error { return boom })
	if !errors.Is(err, boom) {
		t.Fatalf("schedule = %v, want it to wrap %v", err, boom)
	}
}

func TestScheduleRepeatsUntilCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	err := schedule(ctx, time.Millisecond, func(context.Context) error {
		calls++
		if calls == 3 {
			cancel()
		}
		return nil
	})
	if err != nil || calls < 3 {
		t.Fatalf("schedule = %v after %d calls, want nil after at least 3", err, calls)
	}
}
`,
	},
}
