import Testing
@testable import GobiModel

@Suite("Tests panel filter")
struct TestFilterTests {
    private func row(_ title: String, _ depth: Int) -> TestRow {
        TestRow(title: title, depth: depth, status: .passed, elapsedMilliseconds: 0, detail: "")
    }

    private var rows: [TestRow] {
        [row("hello/internal/server", 0), row("TestNewServer", 1), row("TestRunShutsDown", 1), row("graceful", 2), row("TestRunWithTLS", 1),
         row("hello/cmd/hello", 0), row("TestMain", 1)]
    }

    @Test func anEmptyQueryKeepsEverything() {
        #expect(TestFilter.rows(rows, matching: "") == rows)
        #expect(TestFilter.rows(rows, matching: "  ") == rows)
    }

    @Test func aTestMatchesByCaseInsensitiveSubstringAndKeepsItsPackage() {
        #expect(TestFilter.rows(rows, matching: "tls").map(\.title) == ["hello/internal/server", "TestRunWithTLS"])
        #expect(TestFilter.rows(rows, matching: "TESTMAIN").map(\.title) == ["hello/cmd/hello", "TestMain"])
    }

    @Test func aPackageNameMatchKeepsAllItsTests() {
        #expect(TestFilter.rows(rows, matching: "cmd").map(\.title) == ["hello/cmd/hello", "TestMain"])
        #expect(TestFilter.rows(rows, matching: "internal").count == 5)
    }

    @Test func aSubtestKeepsItsParentAndAParentMatchKeepsItsSubtests() {
        #expect(TestFilter.rows(rows, matching: "grace").map(\.title) == ["hello/internal/server", "TestRunShutsDown", "graceful"])
        #expect(TestFilter.rows(rows, matching: "shutsdown").map(\.title) == ["hello/internal/server", "TestRunShutsDown", "graceful"])
    }

    @Test func noMatchLeavesNothing() {
        #expect(TestFilter.rows(rows, matching: "zzz").isEmpty)
    }
}
