//go:build unix

package runner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeModule(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	files["go.mod"] = "module example.com/demo\n\ngo 1.22\n"
	for name, content := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func collect(t *testing.T, run *Run) []Event {
	t.Helper()
	var events []Event
	timeout := time.After(60 * time.Second)
	for {
		select {
		case event, open := <-run.Events():
			if !open {
				return events
			}
			events = append(events, event)
		case <-timeout:
			t.Fatalf("the run did not finish; events so far: %d", len(events))
		}
	}
}

const testFiles = `package demo

import "testing"

func TestOK(t *testing.T) {}

func TestBad(t *testing.T) { t.Fatal("broken on purpose") }

func TestSkipped(t *testing.T) { t.Skip("not today") }
`

func TestTestRunReportsEachTestAndTheExitCode(t *testing.T) {
	dir := writeModule(t, map[string]string{"demo.go": "package demo\n", "demo_test.go": testFiles})
	run, err := Start(context.Background(), Request{Kind: KindTest, Dir: dir, Packages: []string{"./..."}})
	if err != nil {
		t.Fatal(err)
	}
	events := collect(t, run)
	results := map[string]string{}
	var exit *Event
	for index, event := range events {
		switch event.Kind {
		case EventTest:
			if event.Test != "" && (event.Action == "pass" || event.Action == "fail" || event.Action == "skip") {
				results[event.Test] = event.Action
			}
		case EventExit:
			exit = &events[index]
		}
	}
	want := map[string]string{"TestOK": "pass", "TestBad": "fail", "TestSkipped": "skip"}
	for name, action := range want {
		if results[name] != action {
			t.Errorf("%s = %q, want %q (all: %v)", name, results[name], action, results)
		}
	}
	if exit == nil || exit.ExitCode != 1 {
		t.Fatalf("a failing test run exits 1, got %+v", exit)
	}
}

func TestTestFilterRunsOnlyTheMatchingTests(t *testing.T) {
	dir := writeModule(t, map[string]string{"demo.go": "package demo\n", "demo_test.go": testFiles})
	run, err := Start(context.Background(), Request{Kind: KindTest, Dir: dir, Packages: []string{"./..."}, Filter: "^TestOK$"})
	if err != nil {
		t.Fatal(err)
	}
	var seen []string
	var code int
	for _, event := range collect(t, run) {
		if event.Kind == EventTest && event.Test != "" && event.Action == "pass" {
			seen = append(seen, event.Test)
		}
		if event.Kind == EventExit {
			code = event.ExitCode
		}
	}
	if len(seen) != 1 || seen[0] != "TestOK" || code != 0 {
		t.Fatalf("filter ran %v with exit %d, want only TestOK and exit 0", seen, code)
	}
}

func TestRunStreamsProgramOutputAndPassesArguments(t *testing.T) {
	dir := writeModule(t, map[string]string{"main.go": `package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("hello", os.Args[1])
	fmt.Fprintln(os.Stderr, "to stderr")
}
`})
	run, err := Start(context.Background(), Request{Kind: KindRun, Dir: dir, Packages: []string{"."}, Args: []string{"world"}})
	if err != nil {
		t.Fatal(err)
	}
	var stdout, stderr strings.Builder
	var code = -1
	for _, event := range collect(t, run) {
		switch event.Kind {
		case EventOutput:
			if event.Stream == StreamStderr {
				stderr.Write(event.Data)
			} else {
				stdout.Write(event.Data)
			}
		case EventExit:
			code = event.ExitCode
		}
	}
	if !strings.Contains(stdout.String(), "hello world") || !strings.Contains(stderr.String(), "to stderr") || code != 0 {
		t.Fatalf("stdout %q, stderr %q, exit %d", stdout.String(), stderr.String(), code)
	}
}

func TestACompileErrorIsOutputAndANonZeroExit(t *testing.T) {
	dir := writeModule(t, map[string]string{"main.go": "package main\n\nfunc main() { undefined() }\n"})
	run, err := Start(context.Background(), Request{Kind: KindBuild, Dir: dir, Packages: []string{"./..."}})
	if err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	var code int
	for _, event := range collect(t, run) {
		if event.Kind == EventOutput {
			output.Write(event.Data)
		}
		if event.Kind == EventExit {
			code = event.ExitCode
		}
	}
	if !strings.Contains(output.String(), "undefined") || code == 0 {
		t.Fatalf("output %q, exit %d", output.String(), code)
	}
}

func TestBuildAcceptsOnlyTheForceRebuildFlag(t *testing.T) {
	dir := writeModule(t, map[string]string{"main.go": "package main\n\nfunc main() {}\n"})
	ok := Request{Kind: KindBuild, Dir: dir, Packages: []string{"./..."}, Args: []string{"-a"}}
	packages, err := validate(ok)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(commandLine(ok, packages), " "); got != "build -a ./..." {
		t.Errorf("command line = %q", got)
	}
	for _, bad := range [][]string{{"-o", "/tmp/x"}, {"-a", "-x"}} {
		if _, err := validate(Request{Kind: KindBuild, Dir: dir, Args: bad}); err == nil {
			t.Errorf("build arguments %v must be refused", bad)
		}
	}
	if _, err := validate(Request{Kind: KindTest, Dir: dir, Args: []string{"-a"}}); err == nil {
		t.Error("test still takes no arguments")
	}
}

func TestStopEndsALongRunningProgram(t *testing.T) {
	dir := writeModule(t, map[string]string{"main.go": `package main

import (
	"fmt"
	"time"
)

func main() {
	fmt.Println("started")
	time.Sleep(time.Hour)
}
`})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run, err := Start(ctx, Request{Kind: KindRun, Dir: dir, Packages: []string{"."}})
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	go func() {
		for event := range run.Events() {
			if event.Kind == EventOutput && strings.Contains(string(event.Data), "started") {
				close(started)
				return
			}
		}
	}()
	select {
	case <-started:
	case <-time.After(60 * time.Second):
		t.Fatal("the program never started")
	}
	run.Stop()
	done := make(chan struct{})
	go func() {
		for range run.Events() {
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("Stop did not end the run")
	}
}

func TestRequestsAreValidatedBeforeAnythingRuns(t *testing.T) {
	dir := t.TempDir()
	bad := map[string]Request{
		"unknown kind":         {Kind: "install", Dir: dir, Packages: []string{"."}},
		"missing folder":       {Kind: KindTest, Dir: "/definitely/not/here", Packages: []string{"./..."}},
		"relative folder":      {Kind: KindTest, Dir: "relative", Packages: []string{"./..."}},
		"package as a flag":    {Kind: KindTest, Dir: dir, Packages: []string{"-exec=evil"}},
		"package with a space": {Kind: KindTest, Dir: dir, Packages: []string{"./a b"}},
		"package with newline": {Kind: KindTest, Dir: dir, Packages: []string{"./a\nb"}},
		"filter as a flag":     {Kind: KindTest, Dir: dir, Packages: []string{"./..."}, Filter: "-exec"},
		"too many packages":    {Kind: KindTest, Dir: dir, Packages: make([]string, 200)},
		"filter too long":      {Kind: KindTest, Dir: dir, Packages: []string{"./..."}, Filter: strings.Repeat("a", 5000)},
		"arguments for vet":    {Kind: KindVet, Dir: dir, Packages: []string{"./..."}, Args: []string{"x"}},
		"filter for a run":     {Kind: KindRun, Dir: dir, Packages: []string{"."}, Filter: "x"},
		"several packages run": {Kind: KindRun, Dir: dir, Packages: []string{".", "./other"}},
	}
	for name, request := range bad {
		t.Run(name, func(t *testing.T) {
			if _, err := Start(context.Background(), request); err == nil {
				t.Fatalf("%+v must be refused", request)
			}
		})
	}
}

func TestParseTestLine(t *testing.T) {
	event, ok := ParseTestLine(`{"Time":"2026-01-01T00:00:00Z","Action":"fail","Package":"example.com/demo","Test":"TestBad","Elapsed":0.02}`)
	if !ok || event.Action != "fail" || event.Package != "example.com/demo" || event.Test != "TestBad" || event.ElapsedMillis != 20 {
		t.Fatalf("parsed %+v, %v", event, ok)
	}
	output, ok := ParseTestLine(`{"Action":"output","Package":"p","Test":"T","Output":"    x_test.go:5: boom\n"}`)
	if !ok || output.Output != "    x_test.go:5: boom\n" {
		t.Fatalf("output line parsed as %+v, %v", output, ok)
	}
	for _, line := range []string{"", "not json", "{broken", `{"Action":""}`} {
		if _, ok := ParseTestLine(line); ok {
			t.Errorf("%q must not parse as a test event", line)
		}
	}
}
