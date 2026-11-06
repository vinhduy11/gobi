import Testing
@testable import GobiModel

@Suite("Profile filter, source lines and diff")
struct ProfileExtrasTests {
    private func message(_ number: Int, _ build: (inout WireWriter) -> Void) -> [UInt8] {
        var inner = WireWriter()
        build(&inner)
        var outer = WireWriter()
        outer.message(number) { $0 = inner }
        return outer.bytes
    }

    @Test func linesReplyIsRead() throws {
        var head = WireWriter()
        head.string(1, "/p/main.go")
        let bytes = head.bytes + message(2) { $0.uint(1, 12); $0.uint(2, 5); $0.uint(3, 9) } + message(2) { $0.uint(1, 14); $0.uint(3, 3) }
        let lines = try ProfileLines.parse(try WireField.parse(bytes))
        #expect(lines.file == "/p/main.go")
        #expect(lines.rows == [ProfileLineCost(line: 12, flat: 5, cum: 9), ProfileLineCost(line: 14, flat: 0, cum: 3)])
        #expect(lines.cost(atLine: 12)?.cum == 9 && lines.cost(atLine: 13) == nil)
        #expect(lines.firstLine == 12)
    }

    @Test func diffReplyIsReadWithSignedDeltas() throws {
        var head = WireWriter()
        head.string(1, "cpu"); head.string(2, "nanoseconds"); head.uint(3, 100); head.uint(4, 80)
        let bytes = head.bytes
            + message(5) { $0.string(1, "a.slow"); $0.uint(2, 30); $0.uint(3, 5); $0.uint(4, 40); $0.uint(5, 9) }
            + message(5) { $0.string(1, "b.new"); $0.uint(2, 0); $0.uint(3, 20); $0.uint(4, 0); $0.uint(5, 20) }
        let diff = try ProfileDiff.parse(try WireField.parse(bytes))
        #expect(diff.type == "cpu" && diff.unit == "nanoseconds" && diff.baseTotal == 100 && diff.newTotal == 80)
        #expect(diff.rows.map(\.name) == ["a.slow", "b.new"])
        #expect(diff.rows[0].flatDelta == -25 && diff.rows[0].cumDelta == -31 && diff.rows[1].flatDelta == 20)
    }

    @Test func deltasCarryASign() {
        #expect(ProfileFormat.delta(0, unit: "count") == "0")
        #expect(ProfileFormat.delta(20, unit: "count") == "+20")
        #expect(ProfileFormat.delta(-1_500_000_000, unit: "nanoseconds") == "-1.50 s")
    }

    @Test func filterKeepsMatchingFunctionsCaseInsensitively() {
        let rows = [ProfileTopRow(name: "encoding/json.Marshal", flat: 5, cum: 6), ProfileTopRow(name: "main.work", flat: 1, cum: 1)]
        #expect(ProfileFilter.top(rows, query: "JSON").map(\.name) == ["encoding/json.Marshal"])
        #expect(ProfileFilter.top(rows, query: "").count == 2)
        #expect(ProfileFilter.top(rows, query: "  ").count == 2)
        #expect(ProfileFilter.top(rows, query: "zzz").isEmpty)
    }

    @Test func filterKeepsMatchesTheirCallersAndTheirCallees() {
        let nodes = [
            ProfileNode(id: 1, parent: 0, name: "all", flat: 0, cum: 100, file: "", line: 0),
            ProfileNode(id: 2, parent: 1, name: "main.main", flat: 0, cum: 90, file: "", line: 0),
            ProfileNode(id: 3, parent: 2, name: "json.Marshal", flat: 10, cum: 50, file: "", line: 0),
            ProfileNode(id: 4, parent: 3, name: "reflect.Value", flat: 40, cum: 40, file: "", line: 0),
            ProfileNode(id: 5, parent: 2, name: "main.other", flat: 40, cum: 40, file: "", line: 0),
            ProfileNode(id: 6, parent: 1, name: "gc", flat: 10, cum: 10, file: "", line: 0),
        ]
        #expect(ProfileFilter.nodes(nodes, query: "marshal").map(\.id) == [1, 2, 3, 4])
        #expect(ProfileFilter.nodes(nodes, query: "").count == 6)
        #expect(ProfileFilter.nodes(nodes, query: "nothing").isEmpty)
    }
}
