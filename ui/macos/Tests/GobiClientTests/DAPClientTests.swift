import Testing
import GobiModel
@testable import GobiClient

@Suite("DAP client helpers")
struct DAPClientTests {
    @Test func aRequestCarriesSeqCommandAndArguments() throws {
        let bytes = try DAPClient.encodeRequest(seq: 3, command: "next", arguments: ["threadId": 1])
        let json = try #require(DAPClient.decode(bytes))
        #expect(json["seq"] as? Int == 3 && json["type"] as? String == "request" && json["command"] as? String == "next")
        #expect((json["arguments"] as? [String: Any])?["threadId"] as? Int == 1)
    }

    @Test func framesAreReadFromAStackTraceBody() throws {
        let body: [String: Any] = ["stackFrames": [
            ["id": 1000, "name": "main.add", "line": 6, "column": 2, "source": ["path": "/w/main.go", "name": "main.go"]],
            ["id": 1001, "name": "runtime.main", "line": 285, "source": ["path": "/go/src/runtime/proc.go"]],
            ["id": 1002, "name": "no source", "line": 0],
        ]]
        let frames = DAPClient.frames(from: body)
        #expect(frames == [DebugFrame(id: 1000, name: "main.add", path: "/w/main.go", line: 6), DebugFrame(id: 1001, name: "runtime.main", path: "/go/src/runtime/proc.go", line: 285), DebugFrame(id: 1002, name: "no source", path: "", line: 0)])
    }

    @Test func variablesAreReadFromAVariablesBody() {
        let body: [String: Any] = ["variables": [
            ["name": "a", "value": "20", "type": "int", "variablesReference": 0],
            ["name": "s", "value": "*server.Server {…}", "type": "*server.Server", "variablesReference": 1001],
            ["name": "odd"],
        ]]
        #expect(DAPClient.variables(from: body) == [
            DebugVariable(name: "a", type: "int", value: "20", reference: 0),
            DebugVariable(name: "s", type: "*server.Server", value: "*server.Server {…}", reference: 1001),
            DebugVariable(name: "odd", type: "", value: "", reference: 0),
        ])
    }

    @Test func theLocalsScopeIsFoundByName() {
        let body: [String: Any] = ["scopes": [["name": "Arguments", "variablesReference": 1], ["name": "Locals", "variablesReference": 2], ["name": "Globals", "variablesReference": 3]]]
        #expect(DAPClient.localsReference(from: body) == 2)
        #expect(DAPClient.localsReference(from: ["scopes": [["name": "Only", "variablesReference": 9]]]) == 9)
        #expect(DAPClient.localsReference(from: [:]) == nil)
    }
}

@Suite("DAP threads and evaluate")
struct DAPThreadTests {
    @Test func threadsAreReadFromTheThreadsBody() {
        let body: [String: Any] = ["threads": [["id": 1, "name": "Goroutine 1 - User: ./main.go:13 main.main (0x10)"], ["id": 7, "name": "x"], ["name": "no id"]]]
        #expect(DAPClient.threads(from: body) == [DebugThread(id: 1, name: "Goroutine 1 - User: ./main.go:13 main.main (0x10)"), DebugThread(id: 7, name: "x"), DebugThread(id: 0, name: "no id")])
    }

    @Test func breakpointRequestsCarryConditions() {
        var b = Breakpoints()
        b.toggle(path: "/p/a.go", line: 3)
        b.setCondition("x > 1", path: "/p/a.go", line: 9)
        let entries = DAPClient.breakpointEntries(for: "/p/a.go", in: b)
        #expect(entries.count == 2)
        #expect(entries[0]["line"] as? Int == 3 && entries[0]["condition"] == nil)
        #expect(entries[1]["line"] as? Int == 9 && entries[1]["condition"] as? String == "x > 1")
    }
}
