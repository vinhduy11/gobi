import Testing
@testable import GobiModel

@Suite("Run channel messages")
struct RunWireTests {
    // The same bytes core/internal/daemon/run.go reads and writes.
    @Test func startMatchesTheGoLayout() {
        #expect(RunWire.start(command: "test", packages: ["./..."]) == [0x08, 0x01, 0x12, 0x04, 0x74, 0x65, 0x73, 0x74, 0x1a, 0x05, 0x2e, 0x2f, 0x2e, 0x2e, 0x2e])
    }

    @Test func startCarriesFilterAndArguments() throws {
        let bytes = RunWire.start(command: "run", packages: ["."], filter: "", arguments: ["a", "b"])
        let fields = try WireField.parse(bytes)
        #expect(fields.filter { $0.number == 5 }.map(\.string) == ["a", "b"])
        #expect(fields.contains { $0.number == 4 } == false)
        let filtered = try WireField.parse(RunWire.start(command: "test", packages: ["./x"], filter: "^TestA$"))
        #expect(filtered.first { $0.number == 4 }?.string == "^TestA$")
    }

    @Test func stopMatchesTheGoLayout() { #expect(RunWire.stop() == [0x08, 0x02]) }

    @Test func outputIsParsed() throws {
        #expect(try RunWire.parse([0x08, 0x01, 0x12, 0x02, 0x68, 0x69, 0x30, 0x02]) == .output(Array("hi".utf8), stream: 2))
    }

    @Test func exitCarriesCodeAndMessage() throws {
        #expect(try RunWire.parse([0x08, 0x03, 0x60, 0x01]) == .exit(code: 1, message: ""))
        #expect(try RunWire.parse([0x08, 0x03, 0x60, 0x7d, 0x6a, 0x02, 0x6e, 0x6f]) == .exit(code: 125, message: "no"))
    }

    @Test func aTestEventIsParsed() throws {
        var writer = WireWriter()
        writer.uint(1, 2)
        writer.string(7, "fail")
        writer.string(8, "example.com/demo")
        writer.string(9, "TestBad")
        writer.uint(10, 20)
        writer.string(11, "boom\n")
        let event = try RunWire.parse(writer.bytes)
        #expect(event == .test(TestEvent(action: "fail", package: "example.com/demo", test: "TestBad", elapsedMilliseconds: 20, output: "boom\n")))
    }

    @Test func anUnknownKindIsIgnored() throws { #expect(try RunWire.parse([0x08, 0x09]) == .ignored) }
}

@Suite("Test results")
struct TestResultsTests {
    private func event(_ action: String, _ package: String, _ test: String = "", ms: UInt64 = 0, output: String = "") -> TestEvent {
        TestEvent(action: action, package: package, test: test, elapsedMilliseconds: ms, output: output)
    }

    @Test func countsPassedFailedAndSkipped() {
        var results = TestResults()
        for item in [event("pass", "p", "TestA", ms: 10), event("fail", "p", "TestB", ms: 20), event("skip", "p", "TestC"), event("pass", "p", "TestD", ms: 5)] { results.apply(item) }
        #expect(results.passed == 2 && results.failed == 1 && results.skipped == 1)
    }

    @Test func packageEventsAreNotCountedAsTests() {
        var results = TestResults()
        results.apply(event("pass", "p", "TestA"))
        results.apply(event("fail", "p"))
        #expect(results.passed == 1 && results.failed == 0)
        #expect(results.packageStatus("p") == .failed)
    }

    @Test func rowsGroupTestsUnderTheirPackageInOrderOfAppearance() {
        var results = TestResults()
        for item in [event("pass", "a/one", "TestX"), event("fail", "b/two", "TestY"), event("pass", "a/one", "TestZ")] { results.apply(item) }
        results.apply(event("pass", "a/one", ms: 410))
        results.apply(event("fail", "b/two", ms: 100))
        let rows = results.rows()
        #expect(rows.map(\.title) == ["a/one", "TestX", "TestZ", "b/two", "TestY"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0, 1])
        #expect(rows[0].status == .passed && rows[0].elapsedMilliseconds == 410)
        #expect(rows[3].status == .failed)
    }

    @Test func aFailedTestKeepsItsOutputAsDetail() {
        var results = TestResults()
        results.apply(event("run", "p", "TestBad"))
        results.apply(event("output", "p", "TestBad", output: "=== RUN   TestBad\n"))
        results.apply(event("output", "p", "TestBad", output: "    x_test.go:5: boom\n"))
        results.apply(event("fail", "p", "TestBad", ms: 3))
        let row = results.rows().first { $0.title == "TestBad" }
        #expect(row?.detail == "x_test.go:5: boom")
    }

    @Test func aRunningTestShowsAsRunningUntilItFinishes() {
        var results = TestResults()
        results.apply(event("run", "p", "TestSlow"))
        #expect(results.rows().first { $0.title == "TestSlow" }?.status == .running)
        results.apply(event("pass", "p", "TestSlow", ms: 100))
        #expect(results.rows().first { $0.title == "TestSlow" }?.status == .passed)
    }

    @Test func subtestsAreNestedByTheirSlash() {
        var results = TestResults()
        results.apply(event("pass", "p", "TestTable/case_one"))
        results.apply(event("pass", "p", "TestTable"))
        let rows = results.rows()
        #expect(rows.map(\.title) == ["p", "TestTable", "case_one"])
        #expect(rows.map(\.depth) == [0, 1, 2])
    }

    @Test func failedTestNamesCanBeRerun() {
        var results = TestResults()
        for item in [event("pass", "p", "TestA"), event("fail", "p", "TestB"), event("fail", "q", "TestC")] { results.apply(item) }
        #expect(results.failedFilter == "^(TestB|TestC)$")
        #expect(results.failedPackages == ["p", "q"])
        #expect(TestResults().failedFilter == nil)
    }

    @Test func totalTimeIsTheSumOfPackageTimes() {
        var results = TestResults()
        results.apply(event("pass", "a", ms: 410))
        results.apply(event("fail", "b", ms: 1400))
        #expect(results.totalMilliseconds == 1810)
    }

    @Test func clearingForgetsEverything() {
        var results = TestResults()
        results.apply(event("fail", "p", "TestA"))
        results.clear()
        #expect(results.rows().isEmpty && results.failed == 0)
    }
}

@Suite("Test at the cursor")
struct TestAtCursorTests {
    private let source = """
    package demo

    import "testing"

    func helper() {}

    func TestFirst(t *testing.T) {
        helper()
        t.Run("sub", func(t *testing.T) {
            _ = 1
        })
    }

    func TestSecond(t *testing.T) { t.Skip() }

    func BenchmarkSpeed(b *testing.B) {}
    """

    @Test func theCursorInsideATestFindsIt() {
        #expect(TestAtCursor.name(in: source, line: 7) == "TestFirst")
        #expect(TestAtCursor.name(in: source, line: 9) == "TestFirst")
        #expect(TestAtCursor.name(in: source, line: 13) == "TestSecond")
    }

    @Test func theGutterGetsTheSignatureLinesOfTestsAndBenchmarks() {
        #expect(TestAtCursor.signatureLines(in: source) == [7, 14, 16])
        #expect(TestAtCursor.signatureLines(in: "package x\n\nfunc Testing() {}\nfunc Test_x(t *testing.T) {}\n") == [4])
        #expect(TestAtCursor.signatureLines(in: "").isEmpty)
    }

    @Test func theLineOfTheSignatureCounts() {
        #expect(TestAtCursor.name(in: source, line: 6) == "TestFirst")
    }

    @Test func benchmarksAreFoundToo() {
        #expect(TestAtCursor.name(in: source, line: 15) == "BenchmarkSpeed")
    }

    @Test func outsideAnyTestThereIsNothing() {
        #expect(TestAtCursor.name(in: source, line: 4) == nil)
        #expect(TestAtCursor.name(in: source, line: 0) == nil)
    }

    @Test func aHelperAfterATestIsNotThatTest() {
        let text = "func TestA(t *testing.T) {\n}\n\nfunc helper() {\n\tx()\n}\n"
        #expect(TestAtCursor.name(in: text, line: 4) == nil)
    }

    @Test func theFilterMatchesExactlyThatTest() {
        #expect(TestAtCursor.filter(forName: "TestFirst") == "^TestFirst$")
    }
}

@Suite("What to run")
struct RunTargetTests {
    @Test func aMainFileOpenInAFolderRunsThatFolder() {
        #expect(RunTarget.runPackage(currentFileDirectory: "cmd/hello", currentFileIsMain: true, rootHasMain: false, commandFolders: ["cmd/hello", "cmd/other"]) == "./cmd/hello")
    }

    @Test func theRootMainWinsWhenTheOpenFileIsNotMain() {
        #expect(RunTarget.runPackage(currentFileDirectory: "internal/x", currentFileIsMain: false, rootHasMain: true, commandFolders: []) == ".")
    }

    @Test func aSingleCommandFolderIsTheDefault() {
        #expect(RunTarget.runPackage(currentFileDirectory: nil, currentFileIsMain: false, rootHasMain: false, commandFolders: ["cmd/hello"]) == "./cmd/hello")
    }

    @Test func severalCommandsAndNoOpenMainGiveNoGuess() {
        #expect(RunTarget.runPackage(currentFileDirectory: nil, currentFileIsMain: false, rootHasMain: false, commandFolders: ["cmd/a", "cmd/b"]) == nil)
        #expect(RunTarget.runPackage(currentFileDirectory: nil, currentFileIsMain: false, rootHasMain: false, commandFolders: []) == nil)
    }

    @Test func aMainFileAtTheRootIsThePackageDot() {
        #expect(RunTarget.runPackage(currentFileDirectory: "", currentFileIsMain: true, rootHasMain: true, commandFolders: []) == ".")
    }

    @Test func aTestInAFolderRunsThatFoldersPackage() {
        #expect(RunTarget.testPackage(forFile: "internal/server/server_test.go") == "./internal/server")
        #expect(RunTarget.testPackage(forFile: "main_test.go") == ".")
    }

    @Test func theCommandLineIsShownTheWayATerminalWouldTypeIt() {
        #expect(RunTarget.commandLine(command: "test", packages: ["./..."], filter: "^TestA$", arguments: []) == "go test ./... -run ^TestA$")
        #expect(RunTarget.commandLine(command: "run", packages: ["./cmd/hello"], filter: "", arguments: ["-v", "x"]) == "go run ./cmd/hello -v x")
        #expect(RunTarget.commandLine(command: "vet", packages: [], filter: "", arguments: []) == "go vet")
        #expect(RunTarget.commandLine(command: "build", packages: ["./..."], filter: "", arguments: ["-a"]) == "go build -a ./...")
    }
}

@Suite("Run environment file")
struct RunEnvFileTests {
    @Test func theEnvironmentFileIsSentOnlyWhenChosen() throws {
        let plain = RunWire.start(command: "run", packages: ["."])
        var writer = WireWriter()
        writer.uint(1, 1)
        writer.string(2, "run")
        writer.string(3, ".")
        writer.string(4, "")
        #expect(plain == writer.bytes)
        writer.string(6, "-")
        #expect(RunWire.start(command: "run", packages: ["."], envFile: "-") == writer.bytes)
    }
}

@Suite("Run Go folder")
struct RunGoRootTests {
    @Test func theGoFolderIsSentAsField7() {
        var writer = WireWriter()
        writer.uint(1, 1)
        writer.string(2, "vet")
        writer.string(3, "./...")
        writer.string(4, "")
        writer.string(7, "/sdk/go1.25.10")
        #expect(RunWire.start(command: "vet", packages: ["./..."], goRoot: "/sdk/go1.25.10") == writer.bytes)
    }
}

@Suite("Run environment entries")
struct RunEnvironmentTests {
    @Test func entriesAreSentAsRepeatedField8() {
        var writer = WireWriter()
        writer.uint(1, 1); writer.string(2, "run"); writer.string(3, "."); writer.string(4, "")
        writer.string(8, "A=1"); writer.string(8, "B=two")
        #expect(RunWire.start(command: "run", packages: ["."], environment: ["A=1", "B=two"]) == writer.bytes)
    }
}
