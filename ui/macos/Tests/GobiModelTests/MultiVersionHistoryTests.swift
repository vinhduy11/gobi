import Testing
@testable import GobiModel

@Suite("Last multi-version run")
struct MultiVersionHistoryTests {
    private func finishedRows() -> [MultiVersionRow] {
        var passing = MultiVersionRow(version: "1.24.12")
        passing.vetFinished(exitCode: 0)
        var results = TestResults()
        results.apply(TestEvent(action: "pass", package: "p", test: "TestA", elapsedMilliseconds: 1, output: ""))
        passing.testFinished(exitCode: 0, results: results, seconds: 12.4)
        var failing = MultiVersionRow(version: "1.25.10")
        failing.vetFinished(exitCode: 1)
        failing.vetExcerpt = "vet: bad\ttab\nline two \\ slash"
        var failures = TestResults()
        failures.apply(TestEvent(action: "fail", package: "p", test: "TestServer_Run", elapsedMilliseconds: 1, output: ""))
        failing.testFinished(exitCode: 1, results: failures, seconds: 11.8)
        failing.testExcerpt = "--- FAIL: TestServer_Run"
        return [passing, failing]
    }

    @Test func encodeThenDecodeKeepsEverything() {
        let saved = MultiVersionSnapshot(finishedAt: 1_700_000_000, rows: finishedRows())
        let back = MultiVersionSnapshot.decode(saved.encoded)
        #expect(back == saved)
        #expect(back?.rows[0].testText == "Passed · 1 test" && back?.rows[0].timeText == "12.4 s")
        #expect(back?.rows[1].vetText == "Failed" && back?.rows[1].vetExcerpt == "vet: bad\ttab\nline two \\ slash")
        #expect(back?.rows[1].testText == "1 failed · TestServer_Run")
    }

    @Test func garbageDecodesToNothing() {
        #expect(MultiVersionSnapshot.decode("") == nil)
        #expect(MultiVersionSnapshot.decode("nonsense") == nil)
        #expect(MultiVersionSnapshot.decode("v9\t5") == nil)
        #expect(MultiVersionSnapshot.decode("v1\tnotanumber") == nil)
    }

    @Test func restoredRowsCountAsFinished() {
        let back = MultiVersionSnapshot.decode(MultiVersionSnapshot(finishedAt: 1, rows: finishedRows()).encoded)
        #expect(back?.rows.map(\.isFinished) == [true, true])
    }

    @Test func lastRunTextUsesTheInjectedClock() {
        #expect(MultiVersionSnapshot.lastRunText(finishedAt: 1000, now: 1000) == "last run: just now")
        #expect(MultiVersionSnapshot.lastRunText(finishedAt: 1000, now: 1000 + 5 * 60) == "last run: 5 min ago")
        #expect(MultiVersionSnapshot.lastRunText(finishedAt: 1000, now: 1000 + 3 * 3600) == "last run: 3 h ago")
        #expect(MultiVersionSnapshot.lastRunText(finishedAt: 1000, now: 1000 + 2 * 86400) == "last run: 2 d ago")
        #expect(MultiVersionSnapshot.lastRunText(finishedAt: 1000, now: 900) == "last run: just now")
    }

    @Test func excerptKeepsTheLastLinesAndIsShort() {
        #expect(MultiVersionRow.excerpt(of: "a\nb\n\nc\nd\ne\n") == "c\nd\ne")
        #expect(MultiVersionRow.excerpt(of: "") == "")
        #expect(MultiVersionRow.excerpt(of: String(repeating: "x", count: 500)).count == 240)
    }
}
