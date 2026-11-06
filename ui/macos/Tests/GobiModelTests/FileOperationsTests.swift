import Testing
@testable import GobiModel

@Suite("Explorer file operations") struct FileOperationsTests {
    @Test func freeNameKeepsAnUnusedName() {
        #expect(FileOperations.freeName("a.go", existing: ["b.go"]) == "a.go")
    }

    @Test func clashGetsCopySuffixBeforeTheExtension() {
        #expect(FileOperations.freeName("a.go", existing: ["a.go"]) == "a copy.go")
        #expect(FileOperations.freeName("a.go", existing: ["a.go", "a copy.go"]) == "a copy 2.go")
        #expect(FileOperations.freeName("a.go", existing: ["a.go", "a copy.go", "a copy 2.go"]) == "a copy 3.go")
        #expect(FileOperations.freeName("notes", existing: ["notes"]) == "notes copy")
        #expect(FileOperations.freeName(".env", existing: [".env"]) == ".env copy")
        #expect(FileOperations.freeName("a.tar.gz", existing: ["a.tar.gz"]) == "a.tar copy.gz")
    }

    @Test func insideMeansStrictlyUnderTheRoot() {
        #expect(FileOperations.isInside("/p/a/b.go", root: "/p"))
        #expect(FileOperations.isInside("/p/a", root: "/p/"))
        #expect(!FileOperations.isInside("/p", root: "/p"))
        #expect(!FileOperations.isInside("/pp/a", root: "/p"))
        #expect(!FileOperations.isInside("/p/../q/a", root: "/p"))
        #expect(!FileOperations.isInside("/q/a", root: "/p"))
    }

    @Test func aFolderCannotGoIntoItselfOrBelow() {
        #expect(FileOperations.isSameOrInside("/p/a", root: "/p/a"))
        #expect(FileOperations.isSameOrInside("/p/a/b", root: "/p/a"))
        #expect(!FileOperations.isSameOrInside("/p/ab", root: "/p/a"))
    }

    @Test func renameMapsAFileAndOnlyThatFile() {
        let moved = FileOperations.retarget(from: "/p/a.go", to: "/p/b.go", paths: ["/p/a.go", "/p/a.go.bak", "/p/c.go"])
        #expect(moved == [FileOperations.Move(from: "/p/a.go", to: "/p/b.go")])
    }

    @Test func renameOfAFolderMapsNestedFilesWithoutFalsePrefixMatches() {
        let moved = FileOperations.retarget(from: "/p/foo", to: "/p/bar", paths: ["/p/foo/x.go", "/p/foo/sub/y.go", "/p/foobar/z.go", "/p/foo"])
        #expect(moved == [
            FileOperations.Move(from: "/p/foo/x.go", to: "/p/bar/x.go"),
            FileOperations.Move(from: "/p/foo/sub/y.go", to: "/p/bar/sub/y.go"),
            FileOperations.Move(from: "/p/foo", to: "/p/bar"),
        ])
    }

    @Test func deleteTextNamesTheItems() {
        #expect(FileOperations.deleteTitle(names: ["a.go"]) == "Move a.go to the Trash?")
        #expect(FileOperations.deleteTitle(names: ["a.go", "b"]) == "Move 2 items to the Trash?")
        #expect(FileOperations.deleteDetail(names: ["a.go", "b"], unsaved: 0, openTabs: 0) == "a.go, b")
        #expect(FileOperations.deleteDetail(names: ["a.go"], unsaved: 0, openTabs: 2) == "a.go\n2 open tabs will be closed.")
        #expect(FileOperations.deleteDetail(names: ["a.go"], unsaved: 1, openTabs: 1) == "a.go\n1 open tab will be closed. 1 has unsaved changes.")
    }

    @Test func renameSelectsTheNameWithoutItsExtension() {
        #expect(FileOperations.renameSelectionLength("cart.go", isDirectory: false) == 4)
        #expect(FileOperations.renameSelectionLength("a.tar.gz", isDirectory: false) == 5)
        #expect(FileOperations.renameSelectionLength(".env", isDirectory: false) == 4)
        #expect(FileOperations.renameSelectionLength("v1.2", isDirectory: true) == 4)
    }

    @Test func tabStripReplacesAPathInPlace() {
        var tabs = TabStrip()
        tabs.open("/p/a"); tabs.open("/p/b"); tabs.open("/p/c")
        tabs.setDirty("/p/b", true)
        tabs.select("/p/b")
        tabs.replace("/p/b", with: "/p/z")
        #expect(tabs.paths == ["/p/a", "/p/z", "/p/c"])
        #expect(tabs.active == "/p/z")
        #expect(tabs.isDirty("/p/z") && !tabs.isDirty("/p/b"))
    }

    @Test func tabStripPlacesATabAtAnIndex() {
        var tabs = TabStrip()
        tabs.open("/p/a"); tabs.open("/p/b"); tabs.open("/p/c")
        tabs.place("/p/c", at: 0)
        #expect(tabs.paths == ["/p/c", "/p/a", "/p/b"])
        tabs.place("/p/c", at: 9)
        #expect(tabs.paths == ["/p/a", "/p/b", "/p/c"])
    }

    @Test func breakpointsMoveWithTheirFile() {
        var marks = Breakpoints()
        marks.toggle(path: "/p/a.go", line: 3)
        marks.setCondition("x > 1", path: "/p/a.go", line: 9)
        marks.move(from: "/p/a.go", to: "/p/b.go")
        #expect(marks.lines(in: "/p/a.go").isEmpty)
        #expect(marks.lines(in: "/p/b.go") == [3, 9])
        #expect(marks.condition(path: "/p/b.go", line: 9) == "x > 1")
    }
}
