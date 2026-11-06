import Testing
@testable import GobiModel

@Suite("Run on multiple Go versions")
struct MultiVersionRunTests {
    private func results(passed: Int, failed: [String] = []) -> TestResults {
        var r = TestResults()
        for i in 0 ..< passed { r.apply(TestEvent(action: "pass", package: "p", test: "TestOK\(i)", elapsedMilliseconds: 1, output: "")) }
        for name in failed { r.apply(TestEvent(action: "fail", package: "p", test: name, elapsedMilliseconds: 1, output: "")) }
        return r
    }

    @Test func aRowStartsPendingThenShowsEachPhase() {
        var row = MultiVersionRow(version: "1.25.10")
        #expect(row.vetText == "Waiting" && row.testText == "Waiting")
        row.vetStarted()
        #expect(row.vetText == "Running…")
        row.vetFinished(exitCode: 0)
        #expect(row.vetText == "Passed")
        row.testStarted()
        #expect(row.testText == "Running…")
    }

    @Test func testSummaryNamesPassedCountOrTheFirstFailure() {
        var ok = MultiVersionRow(version: "1.24.12")
        ok.testFinished(exitCode: 0, results: results(passed: 42), seconds: 12.4)
        #expect(ok.testText == "Passed · 42 tests")
        #expect(ok.timeText == "12.4 s")
        var bad = MultiVersionRow(version: "1.26.5")
        bad.testFinished(exitCode: 1, results: results(passed: 3, failed: ["TestServer_Run", "TestOther"]), seconds: 11.1)
        #expect(bad.testText == "2 failed · TestServer_Run")
    }

    @Test func aFailureWithNoTestsIsABuildFailure() {
        var row = MultiVersionRow(version: "1.23.12")
        row.vetFinished(exitCode: 2)
        row.testFinished(exitCode: 1, results: TestResults(), seconds: 1)
        #expect(row.vetText == "Failed")
        #expect(row.testText == "Failed to build")
    }

    @Test func oneTestIsSingular() {
        var row = MultiVersionRow(version: "1.25.10")
        row.testFinished(exitCode: 0, results: results(passed: 1), seconds: 0.5)
        #expect(row.testText == "Passed · 1 test")
    }

    @Test func aStoppedRunIsMarkedStopped() {
        var row = MultiVersionRow(version: "1.25.10")
        row.vetStarted()
        row.stopped()
        #expect(row.vetText == "Stopped")
        #expect(row.testText == "Stopped")
    }

    @Test func versionChoicesAreTheNewestPatchOfEachMinor() {
        let installs = [GoInstall(version: "1.26.5", source: "System", location: "/a"), GoInstall(version: "1.25.10", source: "golang.org/dl", location: "/b"), GoInstall(version: "1.25.9", source: "golang.org/dl", location: "/c")]
        #expect(MultiVersionRow.choices(from: installs).map(\.version) == ["1.26.5", "1.25.10"])
    }
}
