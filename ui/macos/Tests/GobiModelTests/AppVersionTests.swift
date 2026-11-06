import Testing
@testable import GobiModel

@Suite("App version") struct AppVersionTests {
    @Test func parsesCoreAndPrerelease() {
        let v = AppVersion.parse("0.1.0-alpha.1")
        #expect(v?.major == 0 && v?.minor == 1 && v?.patch == 0)
        #expect(v?.prerelease == "alpha.1")
        #expect(v?.isPrerelease == true)
    }

    @Test func aReleaseHasNoPrerelease() {
        let v = AppVersion.parse("1.2.3")
        #expect(v?.prerelease == nil && v?.isPrerelease == false)
        #expect(v?.text == "1.2.3")
    }

    @Test func rejectsWhatIsNotSemanticVersioning() {
        for bad in ["", "1", "1.2", "1.2.x", "v1.2.3", "1.2.3-", "1.2.3-alpha..1", "01.2.3", "1.2.3 beta"] {
            #expect(AppVersion.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func ordersByPrecedence() {
        func v(_ s: String) -> AppVersion { AppVersion.parse(s)! }
        #expect(v("0.1.0-alpha.1") < v("0.1.0-alpha.2"))
        #expect(v("0.1.0-alpha.2") < v("0.1.0-beta.1"))
        #expect(v("0.1.0-beta.1") < v("0.1.0-rc.1"))
        #expect(v("0.1.0-rc.1") < v("0.1.0"))
        #expect(v("0.1.0") < v("0.1.1"))
        #expect(v("0.9.0") < v("0.10.0"))
        #expect(v("0.1.0-alpha.2") < v("0.1.0-alpha.10"))
    }

    @Test func theLineShownToPeopleNamesTheBuildAndCommit() {
        #expect(AppVersion.display(version: "0.1.0-alpha.1", build: "123", commit: "abc1234") == "0.1.0-alpha.1 (build 123, abc1234)")
        #expect(AppVersion.display(version: "0.1.0-alpha.1", build: "123", commit: "") == "0.1.0-alpha.1 (build 123)")
        #expect(AppVersion.display(version: "dev", build: "", commit: "") == "dev")
    }
}
