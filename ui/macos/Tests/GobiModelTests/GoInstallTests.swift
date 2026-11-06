import Testing
@testable import GobiModel

@Suite("Go installs")
struct GoInstallTests {
    @Test func sdkFoldersBecomeInstallsNewestFirst() {
        let installs = GoInstalls.fromSDK(folderNames: ["go1.24.12", "go1.25.9", "notes", "go1.9.2", ".DS_Store"], directory: "~/sdk")
        #expect(installs.map(\.version) == ["1.25.9", "1.24.12", "1.9.2"])
        #expect(installs[0].location == "~/sdk/go1.25.9")
        #expect(installs[0].source == "golang.org/dl")
    }

    @Test func theSystemInstallIsMarkedAndSortedIn() {
        let all = GoInstalls.merge(system: GoInstall(version: "1.26.5", source: "System", location: "/usr/local/go"),
                                   sdk: [GoInstall(version: "1.25.9", source: "golang.org/dl", location: "~/sdk/go1.25.9")])
        #expect(all.map(\.version) == ["1.26.5", "1.25.9"])
    }

    @Test func versionsCompareNumerically() {
        #expect(GoInstalls.isNewer("1.10.0", than: "1.9.9"))
        #expect(!GoInstalls.isNewer("1.9.9", than: "1.10.0"))
        #expect(GoInstalls.isNewer("1.26.5", than: "1.26"))
    }

    @Test func projectModeTextSummarisesGoMod() {
        let facts = GoModFacts.parse("module m\n\ngo 1.26\ntoolchain go1.26.5\n")
        #expect(GoInstalls.projectNote(facts) == "go.mod: go 1.26 · toolchain go1.26.5")
        #expect(GoInstalls.projectNote(nil) == "No go.mod")
    }
}

@Suite("Go versions to install")
struct GoAvailableTests {
    private let installed = [GoInstall(version: "1.26.5", source: "System", location: "/usr/local/go"), GoInstall(version: "1.24.12", source: "golang.org/dl", location: "~/sdk/go1.24.12")]

    @Test func rowsMarkInstalledAndLatest() {
        let rows = GoInstalls.installRows(available: ["1.26.6", "1.25.10", "1.24.12"], installed: installed)
        #expect(rows.map(\.version) == ["1.26.6", "1.25.10", "1.24.12"])
        #expect(rows.map(\.state) == [.latest, .available, .installed])
    }

    @Test func aLatestThatIsInstalledIsJustInstalled() {
        let rows = GoInstalls.installRows(available: ["1.26.5"], installed: installed)
        #expect(rows[0].state == .installed)
    }

    @Test func updateNoticeNamesANewerPatchOfTheNewestInstalledMinor() {
        #expect(GoInstalls.updateNotice(available: ["1.26.6", "1.25.10"], installed: installed) == GoUpdate(installed: "1.26.5", available: "1.26.6"))
        #expect(GoInstalls.updateNotice(available: ["1.26.5"], installed: installed) == nil)
        #expect(GoInstalls.updateNotice(available: [], installed: installed) == nil)
        #expect(GoInstalls.updateNotice(available: ["1.26.6"], installed: []) == nil)
    }
}
