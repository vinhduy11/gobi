package lsp

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestInitializeIsServedByTheBrokerAndServerIsShared(t *testing.T) {
	broker := newTestBroker(t)
	first, second := newTestClient(t, broker), newTestClient(t, broker)

	for _, client := range []*testClient{first, second} {
		response := client.initialize()
		if response.Error != nil || !strings.Contains(string(response.Result), "capabilities") {
			t.Fatalf("initialize: %+v / %s", response.Error, response.Result)
		}
	}
	pidFirst := decodeResult[pidResult](t, first.call("fake/pid", nil))
	pidSecond := decodeResult[pidResult](t, second.call("fake/pid", nil))
	if pidFirst.PID == 0 || pidFirst.PID != pidSecond.PID {
		t.Fatalf("both clients must share one server process: %d vs %d", pidFirst.PID, pidSecond.PID)
	}
}

func TestRequestIDsAreTranslatedPerClient(t *testing.T) {
	broker := newTestBroker(t)
	first, second := newTestClient(t, broker), newTestClient(t, broker)
	first.initialize()
	second.initialize()

	hover := func(uri string) map[string]any {
		return map[string]any{"textDocument": map[string]any{"uri": uri}, "delayMs": 100}
	}
	idFirst, waiterFirst := first.start("textDocument/hover", hover("file:///a.go"))
	idSecond, waiterSecond := second.start("textDocument/hover", hover("file:///b.go"))
	if idFirst != idSecond {
		t.Fatalf("test premise: both clients must use the same id, got %d and %d", idFirst, idSecond)
	}

	type hoverResult struct {
		Contents string `json:"contents"`
		SeenID   string `json:"seenID"`
	}
	responseFirst, responseSecond := first.await(waiterFirst), second.await(waiterSecond)
	resultFirst := decodeResult[hoverResult](t, responseFirst)
	resultSecond := decodeResult[hoverResult](t, responseSecond)

	if resultFirst.Contents != "hover:file:///a.go" || resultSecond.Contents != "hover:file:///b.go" {
		t.Fatalf("responses crossed: %q / %q", resultFirst.Contents, resultSecond.Contents)
	}
	if string(responseFirst.ID) != strconv.Itoa(idFirst) || string(responseSecond.ID) != strconv.Itoa(idSecond) {
		t.Fatalf("clients must get their own ids back: %s / %s", responseFirst.ID, responseSecond.ID)
	}
	if resultFirst.SeenID == resultSecond.SeenID {
		t.Fatalf("server must see distinct ids, both were %s", resultFirst.SeenID)
	}
}

func TestCancelRequestIsTranslatedToTheServerID(t *testing.T) {
	broker := newTestBroker(t)
	client := newTestClient(t, broker)
	client.initialize()

	id, waiter := client.start("fake/slow", nil)
	time.Sleep(100 * time.Millisecond)
	client.notify("$/cancelRequest", map[string]any{"id": id})

	response := client.await(waiter)
	if response.Error == nil || response.Error.Code != -32800 {
		t.Fatalf("the fake only answers -32800 when it sees a cancel for its own id, got %+v", response)
	}
}

func TestWorkspaceConfigurationIsAnsweredByTheBroker(t *testing.T) {
	broker := newTestBroker(t)
	client := newTestClient(t, broker)
	client.initialize()

	answers := decodeResult[[]json.RawMessage](t, client.call("fake/askConfiguration", nil))
	if len(answers) != 2 {
		t.Fatalf("want one answer per requested item, got %d", len(answers))
	}
	select {
	case request := <-client.serverRequests:
		t.Fatalf("client must not see workspace/configuration, got %s", request.Method)
	default:
	}
}

func TestApplyEditIsForwardedToTheClientAndTheAnswerRoutedBack(t *testing.T) {
	broker := newTestBroker(t)
	client := newTestClient(t, broker)
	client.initialize()

	_, waiter := client.start("fake/askApplyEdit", nil)
	var request message
	select {
	case request = <-client.serverRequests:
	case <-time.After(waitLimit):
		t.Fatal("client never received the server request")
	}
	if request.Method != "workspace/applyEdit" {
		t.Fatalf("got %s", request.Method)
	}
	client.respond(request.ID, map[string]any{"applied": true})

	relayed := decodeResult[struct {
		Relayed struct{ Applied bool } `json:"relayed"`
		AskedID string                 `json:"askedID"`
	}](t, client.await(waiter))
	if !relayed.Relayed.Applied {
		t.Fatal("the answer must reach the server")
	}
	if string(request.ID) == relayed.AskedID {
		t.Fatalf("client-facing id must differ from the server's own id %s", relayed.AskedID)
	}
}

func TestNotificationsAreBroadcastToEveryClient(t *testing.T) {
	broker := newTestBroker(t)
	first, second := newTestClient(t, broker), newTestClient(t, broker)
	first.initialize()
	second.initialize()

	first.call("fake/notify", nil)
	first.expectNotification("window/showMessage")
	second.expectNotification("window/showMessage")
}

func TestShutdownAndExitFromAClientDoNotStopTheSharedServer(t *testing.T) {
	broker := newTestBroker(t)
	leaving, staying := newTestClient(t, broker), newTestClient(t, broker)
	leaving.initialize()
	staying.initialize()

	if response := leaving.call("shutdown", nil); response.Error != nil {
		t.Fatalf("shutdown: %+v", response.Error)
	}
	leaving.notify("exit", nil)

	if pid := decodeResult[pidResult](t, staying.call("fake/pid", nil)); pid.PID == 0 {
		t.Fatal("server must still answer the other client")
	}
}

func TestRestartFailsInFlightRequestsAndReplaysOpenDocuments(t *testing.T) {
	broker := newTestBroker(t)
	client := newTestClient(t, broker)
	client.initialize()

	client.openDoc("file:///a.go", "package a")
	client.notify("textDocument/didChange", map[string]any{
		"textDocument":   map[string]any{"uri": "file:///a.go", "version": 2},
		"contentChanges": []map[string]any{{"range": map[string]any{"start": map[string]int{"line": 0, "character": 8}, "end": map[string]int{"line": 0, "character": 9}}, "text": "b"}},
	})
	before := decodeResult[pidResult](t, client.call("fake/pid", nil))

	_, slowWaiter := client.start("fake/slow", nil)
	crash := client.call("fake/crash", nil)
	slow := client.await(slowWaiter)
	for name, response := range map[string]message{"crash": crash, "slow": slow} {
		if response.Error == nil || response.Error.Code != codeServerRestarted {
			t.Fatalf("%s request must fail with the restart error, got %+v", name, response)
		}
	}

	restarted := client.expectNotification("gobi/lspRestarted")
	if !strings.Contains(string(restarted.Params), "epoch") {
		t.Fatalf("restart notice should carry the epoch: %s", restarted.Params)
	}
	after := decodeResult[pidResult](t, client.call("fake/pid", nil))
	if after.PID == before.PID {
		t.Fatal("a new server process must be running")
	}
	replayed := decodeResult[[]openDocResult](t, client.call("fake/openDocs", nil))
	if len(replayed) != 1 || replayed[0].URI != "file:///a.go" || replayed[0].Text != "package b" || replayed[0].Version != 2 {
		t.Fatalf("latest document state must be replayed, got %+v", replayed)
	}
}

func TestMalformedServerOutputTriggersRestart(t *testing.T) {
	broker := newTestBroker(t)
	client := newTestClient(t, broker)
	client.initialize()
	before := decodeResult[pidResult](t, client.call("fake/pid", nil))

	if response := client.call("fake/malformed", nil); response.Error == nil {
		t.Fatalf("in-flight request must fail, got %s", response.Result)
	}
	client.expectNotification("gobi/lspRestarted")
	if after := decodeResult[pidResult](t, client.call("fake/pid", nil)); after.PID == before.PID {
		t.Fatal("a new server process must be running")
	}
}

func TestClientDisconnectCancelsItsRequestsAndClosesItsDocuments(t *testing.T) {
	broker := newTestBroker(t)
	leaving, staying := newTestClient(t, broker), newTestClient(t, broker)
	leaving.initialize()
	staying.initialize()

	leaving.openDoc("file:///only-mine.go", "package x")
	leaving.start("fake/slow", nil)
	time.Sleep(100 * time.Millisecond)
	leaving.pipe.Close()

	waitFor(t, "the server to see the cancel", func() bool {
		count := decodeResult[struct{ Count int }](t, staying.call("fake/cancelCount", nil))
		return count.Count >= 1
	})
	waitFor(t, "the document to be closed", func() bool {
		return len(decodeResult[[]openDocResult](t, staying.call("fake/openDocs", nil))) == 0
	})
}

func TestUnavailableServerBinaryIsReportedToTheClient(t *testing.T) {
	broker := newTestBroker(t, "/nonexistent/gopls")
	for attempt := 0; attempt < 2; attempt++ {
		client := newTestClient(t, broker)
		response := client.initialize()
		if response.Error == nil || response.Error.Code != codeServerUnavailable || !strings.Contains(response.Error.Message, "unavailable") {
			t.Fatalf("attempt %d: want codeServerUnavailable, got %+v", attempt, response)
		}
	}
}

func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(waitLimit)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestInitializeAsksGoplsForSemanticTokens(t *testing.T) {
	broker := newTestBroker(t)
	options := func(clientParams string) map[string]any {
		t.Helper()
		var params struct {
			InitializationOptions map[string]any `json:"initializationOptions"`
		}
		if err := json.Unmarshal(broker.buildInitializeParams(json.RawMessage(clientParams)), &params); err != nil {
			t.Fatal(err)
		}
		return params.InitializationOptions
	}
	// gopls sends no semantic tokens unless asked: they are off by default.
	if got := options(`{"capabilities":{}}`); got["ui.semanticTokens"] != true {
		t.Fatalf("semantic tokens must be switched on, got %v", got)
	}
	// What the client set itself stays, and its own choice about semantic tokens wins.
	got := options(`{"capabilities":{},"initializationOptions":{"ui.staticcheck":true,"ui.semanticTokens":false}}`)
	if got["ui.staticcheck"] != true || got["ui.semanticTokens"] != false {
		t.Fatalf("the client's options must be kept, got %v", got)
	}
}
