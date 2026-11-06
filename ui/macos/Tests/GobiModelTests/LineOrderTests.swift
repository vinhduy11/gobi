import Testing
@testable import GobiModel

@Suite("Sort, reverse and recent files")
struct LineOrderTests {
    @Test func sortingOrdersLinesAndKeepsTheFinalNewline() {
        #expect(LineOrder.sorted("b\na\nc\n") == "a\nb\nc\n")
        #expect(LineOrder.sorted("b\na\nc") == "a\nb\nc")
        #expect(LineOrder.sorted("") == "")
        #expect(LineOrder.sorted("\tb\n\ta\n") == "\ta\n\tb\n")
    }

    @Test func reversingFlipsLinesAndKeepsTheFinalNewline() {
        #expect(LineOrder.reversed("1\n2\n3\n") == "3\n2\n1\n")
        #expect(LineOrder.reversed("1\n2") == "2\n1")
        #expect(LineOrder.reversed("x\n") == "x\n")
    }

    @Test func recentFilesKeepTheNewestFirstWithoutDuplicates() {
        var list: [String] = []
        for path in ["/a", "/b", "/a"] { list = RecentFiles.adding(path, to: list) }
        #expect(list == ["/a", "/b"])
        for index in 0 ..< 30 { list = RecentFiles.adding("/f\(index)", to: list) }
        #expect(list.count == RecentFiles.limit && list.first == "/f29")
        #expect(RecentFiles.adding("", to: ["/a"]) == ["/a"])
    }
}
