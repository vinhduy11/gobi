import Testing
@testable import GobiModel

@Suite("Toolchain choice")
struct ToolchainChoiceTests {
    private let system = GoInstall(version: "1.26.5", source: "System", location: "/usr/local/go")
    private let v25 = GoInstall(version: "1.25.10", source: "golang.org/dl", location: "~/sdk/go1.25.10")
    private let v24 = GoInstall(version: "1.24.12", source: "golang.org/dl", location: "~/sdk/go1.24.12")
    private var installs: [GoInstall] { [system, v25, v24] }

    @Test func autoUsesTheSystemGoWhenItMeetsTheGoModLine() {
        let r = ToolchainChoice.resolve(ToolchainSelection(), goMod: GoModFacts.parse("module m\n\ngo 1.25\n"), installs: installs)
        #expect(r == .install(system))
    }

    @Test func autoFollowsAToolchainLineExactly() {
        let facts = GoModFacts.parse("module m\n\ngo 1.24\ntoolchain go1.24.12\n")
        #expect(ToolchainChoice.resolve(ToolchainSelection(), goMod: facts, installs: installs) == .install(v24))
    }

    @Test func autoReportsAMissingVersion() {
        let facts = GoModFacts.parse("module m\n\ngo 1.27\n")
        #expect(ToolchainChoice.resolve(ToolchainSelection(), goMod: facts, installs: installs) == .missing(wanted: "1.27"))
    }

    @Test func autoWithoutAGoModUsesThePathGo() {
        #expect(ToolchainChoice.resolve(ToolchainSelection(), goMod: nil, installs: installs) == .system)
    }

    @Test func autoWithNoInstallsKnownYetUsesThePathGo() {
        let facts = GoModFacts.parse("module m\n\ngo 1.22\n")
        #expect(ToolchainChoice.resolve(ToolchainSelection(), goMod: facts, installs: []) == .system)
    }

    @Test func pinnedUsesThatVersionOrReportsItMissing() {
        let pinned = ToolchainSelection(mode: .pinned, pinnedVersion: "1.25.10")
        #expect(ToolchainChoice.resolve(pinned, goMod: nil, installs: installs) == .install(v25))
        let gone = ToolchainSelection(mode: .pinned, pinnedVersion: "1.20.1")
        #expect(ToolchainChoice.resolve(gone, goMod: nil, installs: installs) == .missing(wanted: "1.20.1"))
    }

    @Test func aMinimumLinePicksTheNewestInstallThatSatisfiesIt() {
        // 1.26.5 is the newest installed and satisfies "go 1.24"; the system go is preferred when it does.
        let facts = GoModFacts.parse("module m\n\ngo 1.24\n")
        #expect(ToolchainChoice.resolve(ToolchainSelection(), goMod: facts, installs: [v24, v25]) == .install(v25))
    }

    @Test func goRootIsEmptyForThePathGoAndExpandedForSdkInstalls() {
        #expect(ToolchainChoice.goRoot(.system, home: "/Users/me") == "")
        #expect(ToolchainChoice.goRoot(.install(v25), home: "/Users/me") == "/Users/me/sdk/go1.25.10")
        #expect(ToolchainChoice.goRoot(.install(system), home: "/Users/me") == "/usr/local/go")
        #expect(ToolchainChoice.goRoot(.missing(wanted: "1.27"), home: "/Users/me") == nil)
    }

    @Test func selectionRoundTrips() {
        let s = ToolchainSelection(mode: .pinned, pinnedVersion: "1.25.10")
        #expect(ToolchainSelection.decode(s.encoded()) == s)
        #expect(ToolchainSelection.decode("junk") == ToolchainSelection())
    }

    @Test func menuTitlesAndCheckMark() {
        let items = ToolchainChoice.menuItems(selection: ToolchainSelection(mode: .pinned, pinnedVersion: "1.25.10"), goMod: GoModFacts.parse("module m\n\ngo 1.25\n"), installs: installs)
        #expect(items.map(\.title) == ["Auto (go.mod: go 1.25)", "go1.26.5", "go1.25.10", "go1.24.12"])
        #expect(items.map(\.isChecked) == [false, false, true, false])
        let auto = ToolchainChoice.menuItems(selection: ToolchainSelection(), goMod: nil, installs: installs)
        #expect(auto[0].title == "Auto" && auto[0].isChecked)
    }
}
