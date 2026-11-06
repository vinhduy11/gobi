//go:build unix

// Package runner runs `go run`, `go test`, `go vet` and `go build` for a project and streams what they do: the output as it
// comes, each test's result read from `go test -json`, and the exit code. It starts the user's own go, as a terminal would.
package runner

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// What to run.
const (
	KindRun   = "run"
	KindTest  = "test"
	KindVet   = "vet"
	KindBuild = "build"
)

// Kinds of Event.
const (
	EventOutput = 1
	EventTest   = 2
	EventExit   = 3
)

// Streams of an output event.
const (
	StreamStdout = 1
	StreamStderr = 2
)

const (
	maxPackages  = 100
	maxPattern   = 200
	maxFilter    = 1000
	maxArguments = 100
	maxArgument  = 1000
	chunkSize    = 32 << 10
	stopGrace    = 3 * time.Second
	eventsBuffer = 256
	maxTestLine  = 1 << 20
)

var patternPattern = regexp.MustCompile(`^[A-Za-z0-9_./@:~+][A-Za-z0-9_./@:~+-]*$`)

// Request describes one run.
type Request struct {
	Kind     string
	Dir      string   // absolute project folder
	Packages []string // package patterns; "./..." for the tests, "." for a run when empty
	Filter   string   // test names to run (go test -run), test only
	Args     []string // arguments for the program, run only
	// EnvFile names a file of KEY=VALUE lines inside Dir to add to the environment. Empty uses Dir/.env when there is one;
	// NoEnvFile uses none.
	EnvFile string
	// GoRoot is the folder of the Go installation to use (it holds bin/go). Empty uses the `go` on PATH. It comes from the user's
	// choice in the app, never from a project file.
	GoRoot string
	// Env is extra KEY=VALUE entries from the user's environment profile; they come after the env file.
	Env []string
}

// Event is one thing a run reports.
type Event struct {
	Kind int
	// Output events.
	Stream int
	Data   []byte
	// Test events, from `go test -json`.
	Action        string // run, pause, cont, pass, fail, skip, output, start
	Package       string
	Test          string // empty for a whole package
	Output        string
	ElapsedMillis uint64
	// Exit events.
	ExitCode int
	Message  string
}

// Run is a started run. Read Events until it closes; the last event is the exit.
type Run struct {
	events   chan Event
	cmd      *exec.Cmd
	stopOnce sync.Once
	finished chan struct{}
}

// Events delivers the run's events and closes after the exit event.
func (r *Run) Events() <-chan Event { return r.events }

// Stop asks the run to end (SIGTERM to its process group) and kills it after a short grace period.
func (r *Run) Stop() {
	r.stopOnce.Do(func() {
		if r.cmd.Process == nil {
			return
		}
		group := -r.cmd.Process.Pid
		syscall.Kill(group, syscall.SIGTERM)
		go func() {
			select {
			case <-r.finished:
			case <-time.After(stopGrace):
				syscall.Kill(group, syscall.SIGKILL)
			}
		}()
	})
}

func validate(request Request) ([]string, error) {
	if !strings.HasPrefix(request.Dir, "/") {
		return nil, errors.New("dir must be an absolute path")
	}
	if info, err := os.Stat(request.Dir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("%q is not a folder", request.Dir)
	}
	if len(request.Packages) > maxPackages {
		return nil, errors.New("too many packages")
	}
	for _, pattern := range request.Packages {
		if len(pattern) > maxPattern || !patternPattern.MatchString(pattern) {
			return nil, fmt.Errorf("package pattern %q is not valid", pattern)
		}
	}
	for _, pattern := range request.Packages {
		if strings.HasSuffix(pattern, ".go") && !safeGoFile(pattern) {
			return nil, fmt.Errorf("go file %q must be inside the folder", pattern)
		}
	}
	packages := request.Packages
	switch request.Kind {
	case KindRun:
		if request.Filter != "" {
			return nil, errors.New("a filter applies to tests only")
		}
		if len(packages) == 0 {
			packages = []string{"."}
		}
		if len(packages) != 1 && !allGoFiles(packages) {
			return nil, errors.New("run takes exactly one package, or Go files")
		}
	case KindTest, KindVet, KindBuild:
		if len(packages) == 0 {
			packages = []string{"./..."}
		}
		if request.Kind != KindTest && request.Filter != "" {
			return nil, errors.New("a filter applies to tests only")
		}
	default:
		return nil, fmt.Errorf("unknown kind %q", request.Kind)
	}
	if request.Kind == KindBuild && len(request.Args) > 0 && !(len(request.Args) == 1 && request.Args[0] == "-a") {
		return nil, errors.New("build takes only the -a argument")
	}
	if request.Kind != KindRun && request.Kind != KindBuild && len(request.Args) > 0 {
		return nil, errors.New("arguments apply to run only")
	}
	if len(request.Filter) > maxFilter || strings.HasPrefix(request.Filter, "-") || strings.ContainsAny(request.Filter, "\x00\n\r") {
		return nil, errors.New("test filter is not valid")
	}
	if len(request.Args) > maxArguments {
		return nil, errors.New("too many arguments")
	}
	for _, argument := range request.Args {
		if len(argument) > maxArgument || strings.ContainsRune(argument, 0) {
			return nil, errors.New("argument is not valid")
		}
	}
	return packages, nil
}

// safeGoFile is a relative .go path that stays inside the run folder.
func safeGoFile(name string) bool {
	if strings.HasPrefix(name, "/") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." {
			return false
		}
	}
	return true
}

func allGoFiles(patterns []string) bool {
	for _, pattern := range patterns {
		if !strings.HasSuffix(pattern, ".go") {
			return false
		}
	}
	return len(patterns) > 0
}

func commandLine(request Request, packages []string) []string {
	switch request.Kind {
	case KindRun:
		return append(append([]string{"run"}, packages...), request.Args...)
	case KindTest:
		args := []string{"test", "-json"}
		if request.Filter != "" {
			args = append(args, "-run="+request.Filter)
		}
		return append(args, packages...)
	case KindVet:
		return append([]string{"vet"}, packages...)
	default:
		return append(append([]string{"build"}, request.Args...), packages...)
	}
}

// Start validates the request and starts the run. Cancelling ctx stops it.
func Start(ctx context.Context, request Request) (*Run, error) {
	packages, err := validate(request)
	if err != nil {
		return nil, err
	}
	if err := checkEnv(request.Env); err != nil {
		return nil, err
	}
	goBinary, toolchainEnv, err := resolveGo(request.GoRoot)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(goBinary, commandLine(request, packages)...)
	cmd.Dir = request.Dir
	fromFile, err := loadEnvFile(request.Dir, request.EnvFile)
	if err != nil {
		return nil, err
	}
	cmd.Env = append(append(append(os.Environ(), fromFile...), request.Env...), toolchainEnv...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	run := &Run{events: make(chan Event, eventsBuffer), cmd: cmd, finished: make(chan struct{})}
	go func() {
		select {
		case <-ctx.Done():
			run.Stop()
		case <-run.finished:
		}
	}()
	go run.pump(request.Kind == KindTest, stdout, stderr)
	return run, nil
}

func (r *Run) pump(parseTests bool, stdout, stderr io.Reader) {
	var readers sync.WaitGroup
	readers.Add(2)
	go func() {
		defer readers.Done()
		if parseTests {
			r.readTestLines(stdout)
		} else {
			r.readChunks(stdout, StreamStdout)
		}
	}()
	go func() {
		defer readers.Done()
		r.readChunks(stderr, StreamStderr)
	}()
	readers.Wait()
	err := r.cmd.Wait()
	code := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			code = 128 + int(status.Signal())
		} else {
			code = exit.ExitCode()
		}
	} else if err != nil {
		code = -1
	}
	close(r.finished)
	r.events <- Event{Kind: EventExit, ExitCode: code}
	close(r.events)
}

func (r *Run) readChunks(source io.Reader, stream int) {
	buffer := make([]byte, chunkSize)
	for {
		count, err := source.Read(buffer)
		if count > 0 {
			r.events <- Event{Kind: EventOutput, Stream: stream, Data: append([]byte(nil), buffer[:count]...)}
		}
		if err != nil {
			return
		}
	}
}

// readTestLines reads `go test -json`. A line that is a test event becomes a test event (and its output text also an output
// event, so the Output panel shows what `go test` would print); any other line, such as a build error, is plain output.
func (r *Run) readTestLines(source io.Reader) {
	scanner := bufio.NewScanner(source)
	scanner.Buffer(make([]byte, 0, 64<<10), maxTestLine)
	for scanner.Scan() {
		line := scanner.Text()
		if event, ok := ParseTestLine(line); ok {
			r.events <- event
			if event.Action == "output" && event.Output != "" {
				r.events <- Event{Kind: EventOutput, Stream: StreamStdout, Data: []byte(event.Output)}
			}
			continue
		}
		r.events <- Event{Kind: EventOutput, Stream: StreamStdout, Data: []byte(line + "\n")}
	}
}

// ParseTestLine reads one line of `go test -json`. It reports false for anything that is not a test event.
func ParseTestLine(line string) (Event, bool) {
	var raw struct {
		Action  string
		Package string
		Test    string
		Output  string
		Elapsed float64
	}
	if line == "" || json.Unmarshal([]byte(line), &raw) != nil || raw.Action == "" {
		return Event{}, false
	}
	return Event{
		Kind: EventTest, Action: raw.Action, Package: raw.Package, Test: raw.Test, Output: raw.Output,
		ElapsedMillis: uint64(raw.Elapsed*1000 + 0.5),
	}, true
}

// resolveGo returns the go binary to run and the environment that makes it the toolchain for everything it starts.
func resolveGo(goRoot string) (string, []string, error) {
	if goRoot == "" {
		path, err := exec.LookPath("go")
		if err != nil {
			return "", nil, errors.New("go was not found")
		}
		return path, nil, nil
	}
	if !filepath.IsAbs(goRoot) {
		return "", nil, fmt.Errorf("the Go folder must be an absolute path: %q", goRoot)
	}
	binary := filepath.Join(goRoot, "bin", "go")
	if info, err := os.Stat(binary); err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return "", nil, fmt.Errorf("%s is not a Go installation (no executable bin/go)", goRoot)
	}
	path := filepath.Join(goRoot, "bin") + string(os.PathListSeparator) + os.Getenv("PATH")
	return binary, []string{"GOROOT=" + goRoot, "GOTOOLCHAIN=local", "PATH=" + path}, nil
}

const (
	maxEnvEntries = 500
	maxEnvValue   = 64 << 10
)

// checkEnv accepts KEY=VALUE entries with a plain name and no NUL byte. Loader variables are refused: they inject code into
// every program the run starts.
func checkEnv(env []string) error {
	if len(env) > maxEnvEntries {
		return fmt.Errorf("too many environment variables (the limit is %d)", maxEnvEntries)
	}
	for _, entry := range env {
		name, value, found := strings.Cut(entry, "=")
		if !found || !envKey.MatchString(name) || len(value) > maxEnvValue || strings.ContainsRune(entry, 0) {
			return fmt.Errorf("not a usable environment entry: %q", truncate(entry))
		}
		if strings.HasPrefix(name, "DYLD_") || strings.HasPrefix(name, "LD_") {
			return fmt.Errorf("%s cannot be set from an environment profile", name)
		}
	}
	return nil
}

func truncate(text string) string {
	if len(text) > 40 {
		return text[:40] + "…"
	}
	return text
}
