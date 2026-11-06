import Testing
@testable import GobiModel

@Suite("Logging, pure parts")
struct LoggingTests {
    @Test func timestampIsUTCWithMilliseconds() {
        #expect(LogFormat.timestamp(unixMillis: 0) == "1970-01-01T00:00:00.000Z")
        #expect(LogFormat.timestamp(unixMillis: 1_793_960_130_123) == "2026-11-06T10:15:30.123Z")
        #expect(LogFormat.timestamp(unixMillis: 951_782_400_000) == "2000-02-29T00:00:00.000Z")   // a leap day
        #expect(LogFormat.timestamp(unixMillis: -1) == "1970-01-01T00:00:00.000Z")                  // clamped, never traps
    }

    @Test func lineHasTimestampLevelMessage() {
        #expect(LogFormat.line(unixMillis: 1_793_960_130_123, level: .warn, message: "gopls missing") == "2026-11-06T10:15:30.123Z WARN gopls missing")
        #expect(LogFormat.line(unixMillis: 0, level: .info, message: "a").contains(" INFO a"))
        #expect(LogFormat.line(unixMillis: 0, level: .error, message: "a").contains(" ERROR a"))
    }

    @Test func aLineNeverSpansTwoLines() {
        let line = LogFormat.line(unixMillis: 0, level: .error, message: "one\ntwo\r\nthree")
        #expect(!line.contains("\n") && !line.contains("\r"))
        #expect(line.hasSuffix("one two three"))
    }

    @Test func rotationDecision() {
        let limit = LogFormat.maxBytes
        #expect(limit == 2 * 1024 * 1024 && LogFormat.keep == 4)
        #expect(!LogFormat.shouldRotate(currentSize: 0, incoming: 100, limit: limit))
        #expect(!LogFormat.shouldRotate(currentSize: limit - 100, incoming: 100, limit: limit))
        #expect(LogFormat.shouldRotate(currentSize: limit - 99, incoming: 100, limit: limit))
        #expect(!LogFormat.shouldRotate(currentSize: 0, incoming: limit + 5, limit: limit))   // an empty file is never rotated for one big line
    }

    @Test func pathsShrinkToTheirBaseName() {
        #expect(LogRedaction.paths("/Users/me/secret-project") == "secret-project")
        #expect(LogRedaction.paths("open /Users/me/work/app/main.go: no such file") == "open main.go: no such file")
        #expect(LogRedaction.paths("root=\"/Users/me/work/app\" failed") == "root=\"app\" failed")
        #expect(LogRedaction.paths("a/b is relative, exit status 1") == "a/b is relative, exit status 1")
        #expect(LogRedaction.paths("/") == "/")
        #expect(LogRedaction.paths("/Users/me/p/ and /opt/go/bin/go") == "p and go")
    }

    @Test func crashNoticeOnlyForARealLaunchWithAMarker() {
        #expect(CrashNotice.previousRunEndedBadly(markerExists: true, selfTest: false))
        #expect(!CrashNotice.previousRunEndedBadly(markerExists: false, selfTest: false))
        #expect(!CrashNotice.previousRunEndedBadly(markerExists: true, selfTest: true))
    }

    @Test func fatalSignalLineIsFixed() {
        #expect(FatalSignal.handled == [11, 6, 10, 4, 8, 5])
        #expect(FatalSignal.line(signal: 6, version: "0.1 (3)") == "FATAL signal 6 Gobi 0.1 (3)\n")
        #expect(FatalSignal.line(signal: 11, version: "x").hasPrefix("FATAL signal 11 "))
    }

    @Test func tailKeepsTheLastLines() {
        let text = (1 ... 100).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let tail = Diagnostics.tail(text, lines: 60)
        #expect(tail.count == 60 && tail.first == "l41" && tail.last == "l100")
        #expect(Diagnostics.tail("", lines: 60).isEmpty)
        #expect(Diagnostics.tail("a\nb", lines: 60) == ["a", "b"])
    }

    private func sampleInput() -> Diagnostics.Input {
        Diagnostics.Input(
            gobiVersion: "0.1", gobiBuild: "7", gobiCommit: "abc1234", gobidVersion: "gobid 0.1 (abc1234) go1.26.5 darwin/arm64",
            macOS: "26.0", architecture: "arm64",
            tools: [ToolStatus(name: "go", required: true, found: true, version: "go1.26.5", path: "/usr/local/go/bin/go"),
                    ToolStatus(name: "dlv", required: false, found: false)],
            daemonPid: 4242, daemonStartedUnix: 1_793_960_130,
            appLog: "2026-11-06T10:15:30.123Z INFO opened /Users/me/secret-project\n",
            daemonLog: "{\"msg\":\"x\",\"root\":\"/Users/me/other\"}\n")
    }

    @Test func reportHasVersionsToolsDaemonAndLogs() {
        let text = Diagnostics.report(sampleInput())
        for want in ["Gobi 0.1 (build 7, abc1234)", "gobid 0.1 (abc1234)", "macOS 26.0", "arm64", "go: go1.26.5 (go)", "dlv: not found",
                     "running, pid 4242, started 2026-11-06T10:15:30.000Z", "--- gobi.log", "--- gobid.log"] {
            #expect(text.contains(want), "missing \(want)")
        }
    }

    @Test func reportHasNoFullPaths() {
        let text = Diagnostics.report(sampleInput())
        #expect(!text.contains("/Users/me") && !text.contains("/usr/local"))
        #expect(text.contains("opened secret-project") && text.contains("\"root\":\"other\""))
    }

    @Test func reportSaysWhenTheDaemonIsNotRunning() {
        var stopped = sampleInput()
        stopped.daemonPid = nil
        stopped.appLog = ""
        #expect(Diagnostics.report(stopped).contains("gobid: not running"))
    }
}
