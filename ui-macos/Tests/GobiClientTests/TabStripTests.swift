import Testing
@testable import GobiClient

@Suite("Tab strip")
struct TabStripTests {
    @Test func openingAddsATabAndActivatesIt() {
        var tabs = TabStrip()
        tabs.open("/a.go")
        tabs.open("/b.go")
        #expect(tabs.paths == ["/a.go", "/b.go"])
        #expect(tabs.active == "/b.go")
    }

    @Test func openingAnOpenFileOnlyActivatesIt() {
        var tabs = TabStrip()
        tabs.open("/a.go")
        tabs.open("/b.go")
        tabs.open("/a.go")
        #expect(tabs.paths == ["/a.go", "/b.go"])
        #expect(tabs.active == "/a.go")
    }

    @Test func closingTheActiveTabActivatesItsRightNeighbourThenTheLeft() {
        var tabs = TabStrip()
        for path in ["/a", "/b", "/c"] { tabs.open(path) }
        tabs.select("/b")
        tabs.close("/b")
        #expect(tabs.active == "/c")
        tabs.close("/c")
        #expect(tabs.active == "/a")
        tabs.close("/a")
        #expect(tabs.active == nil)
        #expect(tabs.paths.isEmpty)
    }

    @Test func closingAnInactiveTabKeepsTheActiveOne() {
        var tabs = TabStrip()
        for path in ["/a", "/b", "/c"] { tabs.open(path) }
        tabs.close("/a")
        #expect(tabs.active == "/c")
        #expect(tabs.paths == ["/b", "/c"])
    }

    @Test func nextAndPreviousWrapAround() {
        var tabs = TabStrip()
        for path in ["/a", "/b", "/c"] { tabs.open(path) }
        tabs.selectNext()
        #expect(tabs.active == "/a")
        tabs.selectPrevious()
        #expect(tabs.active == "/c")
    }

    @Test func nextOnAnEmptyStripDoesNothing() {
        var tabs = TabStrip()
        tabs.selectNext()
        #expect(tabs.active == nil)
    }

    @Test func selectingAnUnknownPathChangesNothing() {
        var tabs = TabStrip()
        tabs.open("/a")
        tabs.select("/zzz")
        #expect(tabs.active == "/a")
    }

    @Test func dirtyMarksFollowThePathAndClearOnClose() {
        var tabs = TabStrip()
        tabs.open("/a")
        tabs.setDirty("/a", true)
        #expect(tabs.isDirty("/a"))
        #expect(tabs.dirtyPaths == ["/a"])
        tabs.close("/a")
        #expect(tabs.dirtyPaths.isEmpty)
        tabs.open("/a")
        #expect(!tabs.isDirty("/a"))
    }
}
