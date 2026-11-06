// What the Tests panel shows: results gathered from `go test -json` events, as counts and as a package/test tree. Strings in
// and out; the app layer draws the rows.

public enum TestStatus: Equatable {
    case running, passed, failed, skipped
}

public struct TestRow: Equatable {
    public var title: String
    public var depth: Int
    public var status: TestStatus
    public var elapsedMilliseconds: UInt64
    /// For a failed test: its output without the "=== RUN" and "--- FAIL" bookkeeping lines.
    public var detail: String
}

public struct TestResults {
    private struct Entry {
        var status: TestStatus
        var elapsed: UInt64 = 0
        var output: [String] = []
    }

    private var packageOrder: [String] = []
    private var packageEntries: [String: Entry] = [:]
    private var testOrder: [String: [String]] = [:]
    private var testEntries: [String: [String: Entry]] = [:]

    public private(set) var passed = 0
    public private(set) var failed = 0
    public private(set) var skipped = 0

    public init() {}

    public var totalMilliseconds: UInt64 { packageEntries.values.reduce(0) { $0 + $1.elapsed } }

    public mutating func clear() { self = TestResults() }

    public mutating func apply(_ event: TestEvent) {
        if !packageOrder.contains(event.package) { packageOrder.append(event.package) }
        if event.test.isEmpty {
            applyToPackage(event)
        } else {
            applyToTest(event)
        }
    }

    private mutating func applyToPackage(_ event: TestEvent) {
        var entry = packageEntries[event.package] ?? Entry(status: .running)
        switch event.action {
        case "pass": entry.status = .passed; entry.elapsed = event.elapsedMilliseconds
        case "fail": entry.status = .failed; entry.elapsed = event.elapsedMilliseconds
        case "skip": entry.status = .skipped
        default: break
        }
        packageEntries[event.package] = entry
    }

    private mutating func applyToTest(_ event: TestEvent) {
        var entries = testEntries[event.package] ?? [:]
        if entries[event.test] == nil {
            entries[event.test] = Entry(status: .running)
            testOrder[event.package, default: []].append(event.test)
        }
        var entry = entries[event.test] ?? Entry(status: .running)
        switch event.action {
        case "output": entry.output.append(event.output)
        case "pass": entry.status = .passed; entry.elapsed = event.elapsedMilliseconds; passed += 1
        case "fail": entry.status = .failed; entry.elapsed = event.elapsedMilliseconds; failed += 1
        case "skip": entry.status = .skipped; entry.elapsed = event.elapsedMilliseconds; skipped += 1
        default: break
        }
        entries[event.test] = entry
        testEntries[event.package] = entries
    }

    public func packageStatus(_ package: String) -> TestStatus? { packageEntries[package]?.status }

    /// The names of the failed tests as one `go test -run` expression, or nil when none failed.
    public var failedFilter: String? {
        let names = packageOrder.flatMap { package in (testOrder[package] ?? []).filter { testEntries[package]?[$0]?.status == .failed && !$0.contains("/") } }
        return names.isEmpty ? nil : "^(" + names.joined(separator: "|") + ")$"
    }

    /// The first failed top-level test, in the order they ran.
    public var firstFailedName: String? {
        for package in packageOrder {
            if let name = (testOrder[package] ?? []).first(where: { testEntries[package]?[$0]?.status == .failed && !$0.contains("/") }) { return name }
        }
        return nil
    }

    public var failedPackages: [String] {
        packageOrder.filter { package in testEntries[package]?.values.contains { $0.status == .failed } ?? false }
    }

    public func rows() -> [TestRow] {
        var rows: [TestRow] = []
        for package in packageOrder {
            let entry = packageEntries[package]
            rows.append(TestRow(title: package, depth: 0, status: entry?.status ?? .running, elapsedMilliseconds: entry?.elapsed ?? 0, detail: ""))
            // Tests in order of first appearance, with a subtest right after its parent.
            let names = testOrder[package] ?? []
            let ordered = names.sorted { left, right in
                let (l, r) = (left.split(separator: "/").first.map(String.init) ?? left, right.split(separator: "/").first.map(String.init) ?? right)
                if l != r { return (names.firstIndex(of: l) ?? 0) < (names.firstIndex(of: r) ?? 0) }
                return left.split(separator: "/").count < right.split(separator: "/").count
            }
            for name in ordered {
                guard let test = testEntries[package]?[name] else { continue }
                let parts = name.split(separator: "/")
                rows.append(TestRow(title: String(parts.last ?? Substring(name)), depth: parts.count, status: test.status, elapsedMilliseconds: test.elapsed,
                                    detail: test.status == .failed ? Self.detail(of: test.output) : ""))
            }
        }
        return rows
    }

    /// The lines a person wants to read: the output minus `=== RUN`, `--- FAIL` and `--- PASS` bookkeeping, trimmed.
    private static func detail(of output: [String]) -> String {
        output.joined().split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }) }
            .filter { !$0.hasPrefix("=== ") && !$0.hasPrefix("--- ") }
            .joined(separator: "\n")
    }
}

public enum TestFilter {
    /// The rows whose test or package name contains `query` (case-insensitive). A package stays when its name or any of its tests
    /// match; a subtest stays with its parent and a matching parent keeps its subtests. A blank query keeps every row.
    public static func rows(_ rows: [TestRow], matching query: String) -> [TestRow] {
        let needle = String(query.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed()).lowercased()
        if needle.isEmpty { return rows }
        var keep = [Bool](repeating: false, count: rows.count)
        var chain: [Bool] = []   // whether the row at each depth on the current path matches by itself
        for (index, row) in rows.enumerated() {
            chain = Array(chain.prefix(row.depth))
            chain.append(contains(row.title.lowercased(), needle))
            keep[index] = chain.contains(true)
        }
        // A kept row keeps its ancestors.
        for index in rows.indices.reversed() where keep[index] && rows[index].depth > 0 {
            var depth = rows[index].depth - 1
            var back = index - 1
            while depth >= 0, back >= 0 {
                if rows[back].depth == depth { keep[back] = true; depth -= 1 }
                back -= 1
            }
        }
        return rows.indices.filter { keep[$0] }.map { rows[$0] }
    }

    private static func contains(_ text: String, _ needle: String) -> Bool {
        let hay = Array(text), pin = Array(needle)
        guard hay.count >= pin.count else { return false }
        for start in 0 ... (hay.count - pin.count) where Array(hay[start ..< start + pin.count]) == pin { return true }
        return false
    }
}

public enum TestAtCursor {
    /// The name of the Test, Benchmark or Fuzz function the zero-based `line` is in (its signature line included), or nil.
    public static func name(in text: String, line: Int) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 0, line < lines.count else { return nil }
        var index = line
        while index >= 0 {
            let current = lines[index]
            if current.hasPrefix("func ") {
                return testName(in: current)
            }
            // A top-level closing brace ends whatever came before; the cursor is then outside any function.
            if index < line, current.hasPrefix("}") { return nil }
            index -= 1
        }
        return nil
    }

    /// The one-based lines whose `func` declares a test, benchmark or fuzz target: where the gutter offers a Run button.
    public static func signatureLines(in text: String) -> [Int] {
        var lines: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.hasPrefix("func ") {
            if testName(in: line) != nil { lines.append(index + 1) }
        }
        return lines
    }

    /// True for Test*, Benchmark* and Fuzz* names (a lower-case letter after the prefix is a helper, not a test).
    public static func isTestName(_ name: String) -> Bool {
        for prefix in ["Test", "Benchmark", "Fuzz"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.isEmpty || !(rest.first?.isLowercase ?? false) { return true }
        }
        return false
    }

    /// The function name when a `func` line declares a test, benchmark or fuzz target with a single parameter.
    private static func testName(in line: Substring) -> String? {
        let afterFunc = line.dropFirst(5)
        guard let open = afterFunc.firstIndex(of: "(") else { return nil }
        let name = afterFunc[afterFunc.startIndex ..< open]
        for prefix in ["Test", "Benchmark", "Fuzz"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            // TestX, Test_x or Test alone; "Testing" style helpers (lower-case letter after the prefix) are not tests.
            if rest.isEmpty || !(rest.first?.isLowercase ?? false) { return String(name) }
        }
        return nil
    }

    public static func filter(forName name: String) -> String { "^" + name + "$" }
}

public enum RunTarget {
    /// The package `Run` starts: the open file's folder when that file is `package main`, else the project root when it has a
    /// main.go, else the only folder under cmd/ that has one. nil when there is no honest guess.
    public static func runPackage(currentFileDirectory: String?, currentFileIsMain: Bool, rootHasMain: Bool, commandFolders: [String]) -> String? {
        if currentFileIsMain, let directory = currentFileDirectory { return directory.isEmpty ? "." : "./" + directory }
        if rootHasMain { return "." }
        return commandFolders.count == 1 ? "./" + commandFolders[0] : nil
    }

    /// "./internal/server" for a test file in that folder, "." for one at the project root.
    public static func testPackage(forFile relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "." }
        return "./" + relativePath[relativePath.startIndex ..< slash]
    }

    /// The command as a person would type it, for the pill in the Output panel.
    public static func commandLine(command: String, packages: [String], filter: String, arguments: [String]) -> String {
        if command == "build" { return (["go", command] + arguments + packages).joined(separator: " ") }   // build flags precede the packages
        var parts = ["go", command] + packages
        if !filter.isEmpty { parts += ["-run", filter] }
        return (parts + arguments).joined(separator: " ")
    }
}
