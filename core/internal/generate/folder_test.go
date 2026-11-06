package generate

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// folderCase renders one Explorer item in a folder: the golden is testdata/golden/folder-<name>.golden and example is a
// _test.go that exercises the generated code in a real module.
type folderCase struct {
	name, id string
	values   []ParamValue
	example  string
}

var folderIDs = []string{"folder-http-handler", "folder-consumer", "folder-repository", "folder-config", "folder-worker"}

func folderCases() []folderCase {
	return []folderCase{
		{name: "http-handler", id: "folder-http-handler", example: `import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUsersHandler(t *testing.T) {
	mux := http.NewServeMux()
	NewUsersHandler(slog.Default()).Register(mux)
	for _, c := range []struct {
		method, path, body string
		want               int
	}{
		{"GET", "/users", "", 200},
		{"GET", "/users/7", "", 200},
		{"POST", "/users", "{\"name\":\"a\"}", 201},
		{"POST", "/users", "not json", 400},
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(c.method, c.path, strings.NewReader(c.body)))
		if rec.Code != c.want {
			t.Errorf("%s %s = %d, want %d", c.method, c.path, rec.Code, c.want)
		}
	}
}
`},
		{name: "consumer", id: "folder-consumer", example: `import (
	"context"
	"errors"
	"log/slog"
	"testing"
)

func TestOrdersConsumer(t *testing.T) {
	source := make(chan OrdersMessage, 3)
	var got []string
	c := NewOrdersConsumer(source, func(ctx context.Context, m OrdersMessage) error {
		got = append(got, string(m.Value))
		if string(m.Value) == "bad" {
			return errors.New("bad message")
		}
		return nil
	}, slog.Default())
	source <- OrdersMessage{Value: []byte("a")}
	source <- OrdersMessage{Value: []byte("bad")}
	source <- OrdersMessage{Value: []byte("b")}
	close(source)
	if err := c.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Errorf("handled %v; a failing message must not stop the consumer", got)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := NewOrdersConsumer(make(chan OrdersMessage), nil, slog.Default()).Run(ctx); !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v", err)
	}
}
`},
		{name: "repository", id: "folder-repository", values: []ParamValue{{Key: "fields", Values: []string{"Name string", "Age int"}}}, example: `import (
	"context"
	"errors"
	"testing"
)

func TestMemoryUserRepository(t *testing.T) {
	var repo UserRepository = NewMemoryUserRepository()
	ctx := context.Background()
	if _, err := repo.Get(ctx, "1"); !errors.Is(err, ErrUserNotFound) {
		t.Fatalf("err = %v", err)
	}
	if err := repo.Save(ctx, User{ID: "1", Name: "ann", Age: 3}); err != nil {
		t.Fatal(err)
	}
	if got, err := repo.Get(ctx, "1"); err != nil || got.Name != "ann" || got.Age != 3 {
		t.Errorf("got %+v, %v", got, err)
	}
	if err := repo.Delete(ctx, "1"); err != nil {
		t.Fatal(err)
	}
	if err := repo.Delete(ctx, "1"); !errors.Is(err, ErrUserNotFound) {
		t.Errorf("second delete err = %v", err)
	}
}
`},
		{name: "config", id: "folder-config", values: []ParamValue{{Key: "fields", Values: []string{"Addr string", "ReadTimeout time.Duration", "Port int", "Debug bool"}}}, example: `import (
	"testing"
	"time"
)

func TestLoadConfig(t *testing.T) {
	t.Setenv("APP_ADDR", "localhost:1")
	t.Setenv("APP_READ_TIMEOUT", "3s")
	t.Setenv("APP_PORT", "8080")
	t.Setenv("APP_DEBUG", "true")
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Addr != "localhost:1" || cfg.ReadTimeout != 3*time.Second || cfg.Port != 8080 || !cfg.Debug {
		t.Errorf("got %+v", cfg)
	}
	t.Setenv("APP_PORT", "x")
	if _, err := LoadConfig(); err == nil {
		t.Error("a bad number must fail")
	}
}
`},
		{name: "worker", id: "folder-worker", example: `import (
	"context"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"
)

func TestWorkerStopsAfterTheWorkInFlight(t *testing.T) {
	var calls, finished atomic.Int32
	w := NewWorker(time.Millisecond, func(ctx context.Context) error {
		calls.Add(1)
		time.Sleep(20 * time.Millisecond)
		finished.Add(1)
		return nil
	}, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error)
	go func() { done <- w.Run(ctx) }()
	time.Sleep(10 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if calls.Load() == 0 || calls.Load() != finished.Load() {
		t.Errorf("started %d, finished %d: Run must wait for the work in flight", calls.Load(), finished.Load())
	}
}
`},
	}
}

func (c folderCase) request(dir string) Request {
	return Request{
		Version: 5, Item: c.id, Target: TargetFile, Values: c.values, GoVersion: "1.22",
		Context: Context{Path: dir, Package: "demo", Kind: KindFolder},
	}
}

func folderOutputs(t *testing.T, c folderCase) map[string]string {
	t.Helper()
	result, err := Render(c.request(t.TempDir()))
	if err != nil {
		t.Fatalf("%s: %v", c.name, err)
	}
	files := map[string]string{}
	for _, f := range result.Files {
		files[filepath.Base(f.Path)] = f.Content
	}
	return files
}

func TestAFolderOffersTheFiveItemsInOrder(t *testing.T) {
	items, err := List(Context{Path: "/p", Kind: KindFolder})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, item := range items {
		ids = append(ids, item.ID)
		if item.Group != "" || len(item.Params) == 0 || item.Title == "" {
			t.Errorf("%s: group %q params %d title %q", item.ID, item.Group, len(item.Params), item.Title)
		}
	}
	if !reflect.DeepEqual(ids, folderIDs) {
		t.Errorf("ids = %v, want %v", ids, folderIDs)
	}
}

func TestFolderItemsAreNotOfferedInAFileAndPatternsNotInAFolder(t *testing.T) {
	items, err := List(Context{Package: "demo", Kind: KindEmpty})
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if strings.HasPrefix(item.ID, "folder-") {
			t.Errorf("%s offered in a file", item.ID)
		}
	}
}

func TestFolderItemsMatchTheirGoldens(t *testing.T) {
	for _, c := range folderCases() {
		t.Run(c.name, func(t *testing.T) { checkGolden(t, "folder-"+c.name, folderOutputs(t, c)) })
	}
}

func TestFolderItemsBuildVetAndTest(t *testing.T) {
	for _, c := range folderCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			dir := t.TempDir()
			files := folderOutputs(t, c)
			files["go.mod"] = "module example.com/demo\n\ngo 1.22\n"
			files["example_test.go"] = "package demo\n\n" + c.example
			for name, content := range files {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			checkToolchain(t, dir)
		})
	}
}

func TestFolderItemsNameTheirFileAfterTheAnswer(t *testing.T) {
	dir := t.TempDir()
	req := folderCases()[0].request(dir)
	req.Values = []ParamValue{{Key: "resource", Values: []string{"orderItems"}}}
	result, err := Render(req)
	if err != nil {
		t.Fatal(err)
	}
	if got := filepath.Base(result.Files[0].Path); got != "order_items_handler.go" || len(result.Edits) != 0 {
		t.Errorf("file = %s, edits = %d", got, len(result.Edits))
	}
}

func TestAFolderItemRefusesToOverwriteAFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "users_handler.go"), []byte("package demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Render(folderCases()[0].request(dir)); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Errorf("err = %v", err)
	}
}

func TestTheConfigLoaderRefusesATypeItCannotRead(t *testing.T) {
	req := folderCases()[3].request(t.TempDir())
	req.Values = []ParamValue{{Key: "fields", Values: []string{"Tags []string"}}}
	if _, err := Render(req); err == nil || !strings.Contains(err.Error(), "cannot be read from the environment") {
		t.Errorf("err = %v", err)
	}
}
