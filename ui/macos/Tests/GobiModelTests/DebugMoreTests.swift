import Testing
@testable import GobiModel

@Suite("Debug extras")
struct DebugMoreTests {
    @Test func conditionsAreKeptPerBreakpointAndSurviveEncoding() {
        var b = Breakpoints()
        b.toggle(path: "/p/a.go", line: 3)
        b.setCondition("len(errc) > 0", path: "/p/a.go", line: 25)
        #expect(b.lines(in: "/p/a.go") == [3, 25])
        #expect(b.condition(path: "/p/a.go", line: 25) == "len(errc) > 0")
        #expect(b.condition(path: "/p/a.go", line: 3) == nil)
        #expect(Breakpoints.decode(b.encoded()) == b)
        b.setCondition("", path: "/p/a.go", line: 25)
        #expect(b.condition(path: "/p/a.go", line: 25) == nil && b.lines(in: "/p/a.go") == [3, 25])
        b.toggle(path: "/p/a.go", line: 25)
        #expect(b.lines(in: "/p/a.go") == [3])
    }

    @Test func conditionsWithSeparatorsRoundTrip() {
        var b = Breakpoints()
        b.setCondition("x == \"a=b,c\"", path: "/p/a b.go", line: 7)
        #expect(Breakpoints.decode(b.encoded()).condition(path: "/p/a b.go", line: 7) == "x == \"a=b,c\"")
    }

    @Test func goroutineTitlesDropDelvesPrefix() {
        #expect(DebugThread(id: 1, name: "Goroutine 1 - User: ./main.go:13 main.main (0x10)").title == "main.main")
        #expect(DebugThread(id: 7, name: "Goroutine 7 - Runtime: /usr/local/go/src/runtime/proc.go:402 runtime.gopark (0x1)").title == "runtime.gopark")
        #expect(DebugThread(id: 1, name: "* [Go 1] main.add (Thread 24736792)").title == "main.add")
        #expect(DebugThread(id: 3, name: "[Go 3] runtime.gopark").title == "runtime.gopark")
        #expect(DebugThread(id: 9, name: "plain").title == "plain")
    }

    @Test func watchListKeepsOrderAndIgnoresBlanksAndDuplicates() {
        var w = WatchList()
        w.add("len(errc)")
        w.add("  ")
        w.add("ctx.Err()")
        w.add("len(errc)")
        #expect(w.expressions == ["len(errc)", "ctx.Err()"])
        #expect(WatchList.decode(w.encoded()) == w)
        w.remove(at: 0)
        #expect(w.expressions == ["ctx.Err()"])
    }

    @Test func inlineValuesAppearOnTheLinesThatUseALocalUpToTheCurrentLine() {
        let lines = ["package main", "", "func add(a, b int) int {", "\tsum := a + b", "\treturn sum", "}"]
        let vars = [DebugVariable(name: "a", type: "int", value: "20", reference: 0), DebugVariable(name: "b", type: "int", value: "22", reference: 0), DebugVariable(name: "~r0", type: "int", value: "0", reference: 0)]
        let inline = InlineValues.compute(lines: lines, currentLine: 4, variables: vars)
        #expect(inline == [3: "a = 20, b = 22", 4: "a = 20, b = 22"])
    }

    @Test func inlineValuesMatchWholeIdentifiersAndShortenLongValues() {
        let lines = ["func f() {", "\tname := namespace + \"x\"", "}"]
        let vars = [DebugVariable(name: "name", type: "string", value: String(repeating: "z", count: 80), reference: 0), DebugVariable(name: "names", type: "int", value: "1", reference: 0)]
        let inline = InlineValues.compute(lines: lines, currentLine: 2, variables: vars)
        #expect(inline[2]?.hasPrefix("name = zzz") == true)
        #expect(inline[2]?.contains("names") == false)
        #expect((inline[2] ?? "").count < 60)
    }

    @Test func processesAreParsedAndFiltered() {
        let output = "    1 /sbin/launchd\n48211 /Users/me/go/bin/hello\n48090 /tmp/x/server\n  bad line\n41002 gopls\n"
        let rows = ProcessRow.parse(output)
        #expect(rows.map(\.pid) == [41002, 48090, 48211])
        #expect(rows.map(\.name) == ["gopls", "server", "hello"])
        #expect(ProcessRow.filter(rows, by: "ser").map(\.name) == ["server"])
        #expect(ProcessRow.filter(rows, by: "482").map(\.pid) == [48211])
        #expect(ProcessRow.filter(rows, by: "").count == 3)
    }
}
