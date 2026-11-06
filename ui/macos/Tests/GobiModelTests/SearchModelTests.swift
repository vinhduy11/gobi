import Testing
@testable import GobiModel

@Suite("Search results and replacing")
struct SearchModelTests {
    private func hit(_ path: String, _ line: Int, _ start: Int, _ end: Int, _ text: String, textStart: Int = 0, replacement: String = "") -> SearchHit {
        SearchHit(path: path, line: line, start: start, end: end, text: text, textStart: textStart, replacement: replacement)
    }

    private func reply(_ hits: [SearchHit], files: Int, skipped: Int, truncated: Bool) -> [WireField] {
        var w = WireWriter()
        for h in hits {
            w.message(1) { m in m.string(1, h.path); m.uint(2, UInt64(h.line)); m.uint(3, UInt64(h.start)); m.uint(4, UInt64(h.end)); m.string(5, h.text); m.uint(6, UInt64(h.textStart)); m.string(7, h.replacement) }
        }
        w.uint(2, UInt64(files)); w.uint(3, UInt64(skipped)); w.bool(4, truncated)
        return (try? WireField.parse(w.bytes)) ?? []
    }

    @Test func aReplyIsReadAndGroupedByFile() throws {
        let hits = [hit("a.go", 5, 0, 3, "sum := 0"), hit("a.go", 7, 4, 7, "    sum += x"), hit("b/c.go", 1, 7, 10, "return sum")]
        let result = try SearchResults.parse(reply(hits, files: 2, skipped: 1, truncated: true))
        #expect(result.hits == hits && result.files == 2 && result.skipped == 1 && result.truncated)
        #expect(result.groups.map(\.path) == ["a.go", "b/c.go"])
        #expect(result.groups.map(\.hits.count) == [2, 1])
        #expect(result.summary == "3 results in 2 files · stopped at the limit · 1 skipped")
        #expect(SearchResults().summary == "No results")
    }

    @Test func theMatchedTextCanBeRecoveredFromAShortenedLine() {
        #expect(hit("a", 0, 0, 3, "sum := 0").matched == "sum")
        #expect(hit("a", 0, 2000, 2003, "…xsumy…", textStart: 1998).matched == "sum" || hit("a", 0, 2000, 2003, "xxsumyy", textStart: 1998).matched == "sum")
    }

    @Test func replacingOneLineKeepsTheRest() {
        let text = "one sum\ntwo sum sum\nthree\n"
        let hits = [hit("a", 0, 4, 7, "one sum", replacement: "total"), hit("a", 1, 4, 7, "two sum sum", replacement: "total"), hit("a", 1, 8, 11, "two sum sum", replacement: "total")]
        let plan = ReplacePlan.make(hits: hits, text: text)
        #expect(plan.skipped == 0 && plan.edits.count == 3)
        #expect(plan.apply(to: text) == "one total\ntwo total total\nthree\n")
    }

    @Test func aMatchThatChangedSinceTheSearchIsSkipped() {
        let text = "one sun\ntwo sum\n"
        let hits = [hit("a", 0, 4, 7, "one sum", replacement: "total"), hit("a", 1, 4, 7, "two sum", replacement: "total"), hit("a", 9, 0, 3, "gone", replacement: "x")]
        let plan = ReplacePlan.make(hits: hits, text: text)
        #expect(plan.edits.count == 1 && plan.skipped == 2)
        #expect(plan.apply(to: text) == "one sun\ntwo total\n")
    }

    @Test func columnsCountUTF16UnitsAndCRLFIsKept() {
        let text = "😀 sum\r\nx sum\r\n"
        let hits = [hit("a", 0, 3, 6, "😀 sum", replacement: "ok"), hit("a", 1, 2, 5, "x sum", replacement: "ok")]
        #expect(ReplacePlan.make(hits: hits, text: text).apply(to: text) == "😀 ok\r\nx ok\r\n")
    }

    @Test func editsAreGivenFromTheEndSoTheyCanBeAppliedInOrder() {
        let plan = ReplacePlan.make(hits: [hit("a", 0, 0, 1, "a b", replacement: "XX"), hit("a", 0, 2, 3, "a b", replacement: "YY")], text: "a b")
        #expect(plan.edits.map(\.start) == [2, 0])
    }

    @Test func includeFiltersAreSplitOnCommas() {
        #expect(SearchOptionsText.globs("*.go, internal/**.go ,,") == ["*.go", "internal/**.go"])
        #expect(SearchOptionsText.globs("").isEmpty)
    }
}
