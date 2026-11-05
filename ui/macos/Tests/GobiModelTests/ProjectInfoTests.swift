import Testing
@testable import GobiModel

@Suite("Project facts shown on the Welcome window")
struct ProjectInfoTests {
    @Test func countsModulesInAGoWorkFile() {
        #expect(GoWork.moduleCount("go 1.22\n\nuse ./a\nuse ./b\n") == 2)
        #expect(GoWork.moduleCount("go 1.22\n\nuse (\n\t./a\n\t./b // second\n\t./c\n)\n") == 3)
        #expect(GoWork.moduleCount("go 1.22\n\nuse ./a\nuse (\n./b\n)\n") == 2)
    }

    @Test func ignoresCommentsAndOtherDirectives() {
        #expect(GoWork.moduleCount("go 1.22\n// use ./nope\nreplace x => ./y\nuse ./a\n") == 1)
        #expect(GoWork.moduleCount("") == 0)
    }

    @Test func branchComesFromTheHeadFile() {
        #expect(GitHead.branch("ref: refs/heads/main\n") == "main")
        #expect(GitHead.branch("ref: refs/heads/feat/graceful-shutdown\n") == "feat/graceful-shutdown")
    }

    @Test func aDetachedHeadShowsAShortHash() {
        #expect(GitHead.branch("0123456789abcdef0123456789abcdef01234567\n") == "0123456")
    }

    @Test func anEmptyOrUnknownHeadHasNoBranch() {
        #expect(GitHead.branch("") == nil)
        #expect(GitHead.branch("garbage here\n") == nil)
    }

    @Test func searchMatchesNameOrPathIgnoringCase() {
        var recents = RecentProjects()
        recents.add(path: "/work/Hello", kind: .module)
        recents.add(path: "/work/device-service", kind: .workspace)
        recents.add(path: "/desktop/scratch", kind: .folder)
        #expect(recents.matching("HELLO").map(\.path) == ["/work/Hello"])
        #expect(recents.matching("desktop").map(\.path) == ["/desktop/scratch"])
        #expect(recents.matching("").count == 3)
        #expect(recents.matching("zzz").isEmpty)
    }

    @Test func goVersionIsReadFromGoEnvOutput() {
        #expect(GoVersion.display(fromGoEnv: "go1.26.5\n") == "1.26.5")
        #expect(GoVersion.display(fromGoEnv: "go1.23rc1") == "1.23rc1")
        #expect(GoVersion.display(fromGoEnv: "") == nil)
        #expect(GoVersion.display(fromGoEnv: "devel go1.27-abc") == nil)
    }
}
