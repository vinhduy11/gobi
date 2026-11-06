import Testing
@testable import GobiModel

@Suite("Replace selection and search history")
struct ReplaceSelectionTests {
    private func hit(_ path: String, _ line: Int, _ start: Int = 0, replacement: String = "x") -> SearchHit {
        SearchHit(path: path, line: line, start: start, end: start + 3, text: "sum", textStart: 0, replacement: replacement)
    }

    @Test func excludedFilesAreLeftOutOfReplaceAll() {
        let hits = [hit("a.go", 1), hit("b.go", 2), hit("a.go", 3)]
        #expect(ReplaceSelection.included(hits, excludingPaths: ["b.go"]).map(\.line) == [1, 3])
        #expect(ReplaceSelection.included(hits, excludingPaths: []) == hits)
    }

    @Test func aSingleReplaceKeepsOnlyTheHitAtTheSameSpot() {
        let chosen = [hit("a.go", 3, 4)]
        let fresh = [hit("a.go", 1), hit("a.go", 3, 4, replacement: "total"), hit("b.go", 3, 4)]
        #expect(ReplaceSelection.refresh(fresh, chosen: chosen, exact: true).map(\.replacement) == ["total"])
        #expect(ReplaceSelection.refresh(fresh, chosen: chosen, exact: false).map(\.path) == ["a.go", "a.go"])
    }

    @Test func historyKeepsTheNewestFirstWithoutDuplicatesUpToTen() {
        var history: [String] = []
        for query in ["a", "b", "a", ""] { history = SearchHistory.adding(query, to: history) }
        #expect(history == ["a", "b"])
        for index in 0 ..< 15 { history = SearchHistory.adding("q\(index)", to: history) }
        #expect(history.count == 10 && history.first == "q14" && history.last == "q5")
    }
}
