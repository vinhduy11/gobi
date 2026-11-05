import Testing
@testable import GobiModel

@Suite("Project model")
struct ProjectModelTests {
    @Test func aWorkFileMakesAWorkspaceAndBeatsGoMod() {
        #expect(ProjectKind.detect(entryNames: ["go.mod", "go.work", "main.go"]) == .workspace)
    }

    @Test func goModMakesAModule() {
        #expect(ProjectKind.detect(entryNames: ["go.mod", "main.go"]) == .module)
    }

    @Test func aFolderWithoutGoModIsPlain() {
        #expect(ProjectKind.detect(entryNames: ["main.go", "README.md"]) == .folder)
    }

    @Test func treeOrderPutsFoldersFirstThenNamesIgnoringCase() {
        let entries = [
            FileEntry(name: "zeta.go", isDirectory: false), FileEntry(name: "Beta", isDirectory: true),
            FileEntry(name: "alpha.go", isDirectory: false), FileEntry(name: "cmd", isDirectory: true),
        ]
        #expect(FileTree.ordered(entries).map(\.name) == ["Beta", "cmd", "alpha.go", "zeta.go"])
    }

    @Test func treeHidesGitFolderAndMacMetadataButKeepsOtherDotFiles() {
        let entries = [
            FileEntry(name: ".git", isDirectory: true), FileEntry(name: ".DS_Store", isDirectory: false),
            FileEntry(name: ".gitignore", isDirectory: false), FileEntry(name: ".env.example", isDirectory: false),
        ]
        #expect(FileTree.ordered(entries).map(\.name) == [".env.example", ".gitignore"])
    }

    @Test func recentsPutTheNewestFirstWithoutDuplicates() {
        var recents = RecentProjects(limit: 3)
        recents.add(path: "/a", kind: .module)
        recents.add(path: "/b", kind: .folder)
        recents.add(path: "/a", kind: .workspace)   // opened again: moves to the front, kind refreshed
        #expect(recents.items.map(\.path) == ["/a", "/b"])
        #expect(recents.items[0].kind == .workspace)
    }

    @Test func recentsDropTheOldestPastTheLimit() {
        var recents = RecentProjects(limit: 2)
        for path in ["/a", "/b", "/c"] { recents.add(path: path, kind: .module) }
        #expect(recents.items.map(\.path) == ["/c", "/b"])
    }

    @Test func recentsRemoveOnePath() {
        var recents = RecentProjects(limit: 5)
        recents.add(path: "/a", kind: .module)
        recents.add(path: "/b", kind: .module)
        recents.remove(path: "/a")
        #expect(recents.items.map(\.path) == ["/b"])
    }
}

@Suite("Workspace trust list")
struct TrustListTests {
    @Test func aTrustedPathCoversItselfAndWhatIsInsideIt() {
        var trust = TrustList()
        trust.trust(path: "/work/hello")
        #expect(trust.isTrusted(path: "/work/hello"))
        #expect(trust.isTrusted(path: "/work/hello/cmd/main.go"))
    }

    @Test func aSiblingWithTheSamePrefixIsNotTrusted() {
        var trust = TrustList()
        trust.trust(path: "/work/hello")
        #expect(!trust.isTrusted(path: "/work/hello-other"))
        #expect(!trust.isTrusted(path: "/work"))
    }

    @Test func trustingAParentFolderCoversItsProjects() {
        var trust = TrustList()
        trust.trust(path: "/work/")
        #expect(trust.isTrusted(path: "/work/hello"))
    }

    @Test func nothingIsTrustedByDefault() {
        #expect(!TrustList().isTrusted(path: "/work/hello"))
    }
}

@Suite("Project to reopen at launch")
struct LaunchProjectTests {
    @Test func theNewestExistingProjectIsChosen() {
        var recents = RecentProjects(limit: 5)
        recents.add(path: "/old", kind: .module)
        recents.add(path: "/gone", kind: .module)
        recents.add(path: "/newest-missing", kind: .module)
        let found = recents.mostRecent(whereExists: { $0 != "/newest-missing" && $0 != "/gone" })
        #expect(found?.path == "/old")
    }

    @Test func noRecentsGivesNothing() {
        #expect(RecentProjects().mostRecent(whereExists: { _ in true }) == nil)
    }

    @Test func whenNothingExistsAnymoreThereIsNothingToOpen() {
        var recents = RecentProjects()
        recents.add(path: "/a", kind: .folder)
        #expect(recents.mostRecent(whereExists:) { _ in false } == nil)
    }
}

@Suite("Recent projects menu")
struct RecentMenuTests {
    @Test func clearingEmptiesTheList() {
        var recents = RecentProjects()
        recents.add(path: "/a", kind: .module)
        recents.add(path: "/b", kind: .folder)
        recents.clear()
        #expect(recents.items.isEmpty)
    }

    @Test func theMenuShowsTheNewestFirstAndAtMostTheGivenCount() {
        var recents = RecentProjects(limit: 10)
        for name in ["/a", "/b", "/c", "/d"] { recents.add(path: name, kind: .module) }
        #expect(recents.menuItems(limit: 3).map(\.path) == ["/d", "/c", "/b"])
    }

    @Test func projectsWithTheSameFolderNameGetTheirParentFolderToTellThemApart() {
        var recents = RecentProjects()
        recents.add(path: "/work/one/app", kind: .module)
        recents.add(path: "/work/two/app", kind: .module)
        recents.add(path: "/work/solo", kind: .module)
        let titles = recents.menuItems(limit: 10).map(\.title)
        #expect(titles == ["solo", "app — two", "app — one"])
    }
}
