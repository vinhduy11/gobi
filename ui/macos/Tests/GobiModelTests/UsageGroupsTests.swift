import Testing
import GobiModel

private typealias Where = GobiModel.SourceLocation

@Suite("Usage groups")
struct UsageGroupsTests {
    private func pos(_ line: Int, _ character: Int = 0) -> LSPPosition { LSPPosition(line: line, character: character) }
    private func loc(_ uri: String, _ line: Int, _ start: Int = 4, _ end: Int = 9) -> Where {
        Where(uri: uri, start: pos(line, start), end: pos(line, end))
    }
    private func symbol(_ uri: String, _ name: String, _ from: Int, _ to: Int, kind: OutlineSymbol.Kind = .function, children: [DocumentSymbolInfo] = []) -> DocumentSymbolInfo {
        DocumentSymbolInfo(uri: uri, name: name, detail: "", kind: kind, range: (pos(from), pos(to + 1)), selection: (pos(from, 5), pos(from, 9)), children: children, version: 1)
    }

    private let main = "file:///p/cmd/main.go", server = "file:///p/internal/server.go", test = "file:///p/internal/server_test.go"

    @Test func usagesGroupByFileThenEnclosingFunctionThenLine() {
        let symbols = [
            main: [symbol(main, "main", 3, 9)],
            server: [symbol(server, "(*Server).Run", 5, 12), symbol(server, "helper", 14, 20)],
        ]
        let result = UsageGroups.build(locations: [loc(server, 16), loc(main, 7), loc(server, 6), loc(server, 11)], symbols: symbols)
        #expect(result.files.map(\.uri) == [main, server])
        #expect(result.files[1].functions.map(\.name) == ["Server.Run", "helper"])
        #expect(result.files[1].functions[0].lines.map(\.line) == [6, 11])
        #expect(result.total == 4 && result.hidden == 0)
    }

    @Test func aUsageOutsideEveryDeclarationOrInAFileWithoutSymbolsIsFileScope() {
        let result = UsageGroups.build(locations: [loc(main, 1), loc(server, 3)], symbols: [main: [symbol(main, "main", 3, 9)]])
        #expect(result.files[0].functions.map(\.name) == [nil])
        #expect(result.files[1].functions.map(\.name) == [nil])
    }

    @Test func aNestedDeclarationIsNamedAfterItsParent() {
        let field = symbol(server, "Addr", 4, 4)
        let type = symbol(server, "Server", 3, 6, kind: .type, children: [field])
        let result = UsageGroups.build(locations: [loc(server, 4)], symbols: [server: [type]])
        #expect(result.files[0].functions.map(\.name) == ["Server.Addr"])
    }

    @Test func linesInOneFunctionAreOrderedByPositionAndRepeatedLocationsCollapse() {
        let symbols = [main: [symbol(main, "main", 0, 30)]]
        let result = UsageGroups.build(locations: [loc(main, 9, 8, 12), loc(main, 9, 2, 6), loc(main, 9, 2, 6), loc(main, 4)], symbols: symbols)
        let lines = result.files[0].functions[0].lines
        #expect(lines.map { [$0.line, $0.start] } == [[4, 4], [9, 2], [9, 8]])
    }

    @Test func theTestsFilterDropsTestFilesAndTheCountsFollowIt() {
        let all = [loc(main, 1), loc(test, 2), loc(test, 3)]
        let withTests = UsageGroups.build(locations: all, symbols: [:])
        let without = UsageGroups.build(locations: all, symbols: [:], includeTests: false)
        #expect(withTests.total == 3 && withTests.files.count == 2)
        #expect(without.total == 1 && without.files.map(\.uri) == [main])
        #expect(withTests.files[1].isTest && !withTests.files[0].isTest)
    }

    @Test func atMostTheLimitIsShownAndTheRestIsCounted() {
        let many = (0 ..< 12).map { loc(main, $0) }
        let result = UsageGroups.build(locations: many, symbols: [:], limit: 5)
        #expect(result.total == 12 && result.shown == 5 && result.hidden == 7)
        #expect(result.files[0].functions[0].lines.map(\.line) == [0, 1, 2, 3, 4])
        #expect(UsageGroups.pageSize == 5000)
    }

    @Test func theDeclarationNamesTheSymbol() {
        let method = symbol(server, "(*Server).Start", 5, 12)
        let result = UsageGroups.build(locations: [Where(uri: server, start: pos(5, 5), end: pos(5, 9)), loc(main, 3)], symbols: [server: [method]])
        #expect(result.declaration == "Server.Start")
        #expect(UsageGroups.build(locations: [loc(main, 3)], symbols: [:]).declaration == nil)
    }

    @Test func headersCountUsagesAndFiles() {
        #expect(UsageGroups.summary(usages: 12, files: 4) == "12 in 4 files")
        #expect(UsageGroups.summary(usages: 1, files: 1) == "1 in 1 file")
        #expect(UsageGroups.summary(usages: 0, files: 0) == "none")
    }

    @Test func nextAndPreviousWrapAround() {
        #expect(UsageGroups.step(from: nil, by: 1, count: 3) == 0)
        #expect(UsageGroups.step(from: nil, by: -1, count: 3) == 2)
        #expect(UsageGroups.step(from: 2, by: 1, count: 3) == 0)
        #expect(UsageGroups.step(from: 0, by: -1, count: 3) == 2)
        #expect(UsageGroups.step(from: 0, by: 1, count: 0) == nil)
    }

    @Test func theExcerptTrimsIndentationAndKeepsTheMatchInside() {
        let e = UsageGroups.excerpt("\t\ts.Start(ctx)", start: 4, end: 9)
        #expect(e.text == "s.Start(ctx)")
        #expect((e.matchStart, e.matchEnd) == (2, 7))
        let clipped = UsageGroups.excerpt("x", start: 3, end: 8)
        #expect(clipped.matchStart == clipped.matchEnd)
    }

    @Test func aLocationIsStillThereOnlyWhenTheLineHoldsTheSameText() {
        #expect(UsageGroups.isStillThere(cached: "s.Start()", current: "s.Start()"))
        #expect(!UsageGroups.isStillThere(cached: "s.Start()", current: "// moved"))
        #expect(!UsageGroups.isStillThere(cached: "s.Start()", current: nil))
    }
}

@Suite("Usage context staleness")
struct UsageContextTests {
    @Test func aChangedContributingDocumentMakesTheResultStale() {
        let context = UsageContext(originURI: "file:///a.go", position: LSPPosition(line: 1, character: 2), symbol: "Start", versions: ["file:///a.go": 3, "file:///b.go": 1])
        #expect(!context.isStale { ["file:///a.go": 3, "file:///b.go": 1][$0] })
        #expect(context.isStale { $0 == "file:///a.go" ? 4 : 1 })
        #expect(context.isStale { $0 == "file:///b.go" ? 2 : 3 })
    }

    @Test func aFileThatWasClosedAndIsOpenAtItsFirstVersionIsNotStale() {
        let context = UsageContext(originURI: "file:///a.go", position: LSPPosition(line: 0, character: 0), symbol: "X", versions: [:], files: ["file:///c.go"])
        #expect(!context.isStale { _ in 1 })
        #expect(context.isStale { _ in 2 })
        #expect(!context.isStale { _ in nil })
    }
}
