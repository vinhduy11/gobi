/// One line of the "Run on multiple Go versions" table: go vet and go test for one Go version (Toolchains mock).
public struct MultiVersionRow: Equatable {
    private enum Phase: Equatable { case waiting, running, passed(String), failed(String), stopped }

    public let version: String
    private var vet = Phase.waiting
    private var test = Phase.waiting
    public private(set) var timeText = ""
    /// The tail of each command's output, shown as a tooltip.
    public var vetExcerpt = ""
    public var testExcerpt = ""

    public init(version: String) { self.version = version }

    public var vetText: String { Self.text(vet) }
    public var testText: String { Self.text(test) }
    public var isFinished: Bool { [vet, test].allSatisfy { if case .waiting = $0 { return false }; if case .running = $0 { return false }; return true } }

    public mutating func vetStarted() { vet = .running }
    public mutating func vetFinished(exitCode: Int) { vet = exitCode == 0 ? .passed("Passed") : .failed("Failed") }
    public mutating func testStarted() { test = .running }

    public mutating func testFinished(exitCode: Int, results: TestResults, seconds: Double) {
        let tenths = Int((seconds * 10).rounded())
        timeText = "\(tenths / 10).\(tenths % 10) s"
        let counted = results.passed + results.failed
        if results.failed > 0 {
            test = .failed("\(results.failed) failed" + (results.firstFailedName.map { " · " + $0 } ?? ""))
        } else if exitCode != 0 && counted == 0 {
            test = .failed("Failed to build")
        } else if exitCode != 0 {
            test = .failed("Failed")
        } else {
            test = .passed("Passed · \(counted) test" + (counted == 1 ? "" : "s"))
        }
    }

    /// A finished row rebuilt from saved texts: passed when the text starts with "Passed".
    init(version: String, vet: String, test: String, time: String, vetExcerpt: String, testExcerpt: String) {
        self.version = version
        self.vet = Self.restored(vet)
        self.test = Self.restored(test)
        timeText = time
        self.vetExcerpt = vetExcerpt
        self.testExcerpt = testExcerpt
    }

    private static func restored(_ text: String) -> Phase {
        if text == "Stopped" { return .stopped }
        return text.hasPrefix("Passed") ? .passed(text) : .failed(text)
    }

    /// The last three non-empty lines of `output`, at most 240 characters.
    public static func excerpt(of output: String) -> String {
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        return String(lines.suffix(3).joined(separator: "\n").prefix(240))
    }

    /// The run was stopped before this version finished.
    public mutating func stopped() {
        if vet == .waiting || vet == .running { vet = .stopped }
        if test == .waiting || test == .running { test = .stopped }
    }

    private static func text(_ phase: Phase) -> String {
        switch phase {
        case .waiting: return "Waiting"
        case .running: return "Running…"
        case .passed(let text), .failed(let text): return text
        case .stopped: return "Stopped"
        }
    }

    /// The versions the sheet offers: the newest installed patch of each minor, newest first.
    public static func choices(from installs: [GoInstall]) -> [GoInstall] {
        var newest: [String: GoInstall] = [:]
        for install in installs {
            let minor = install.version.split(separator: ".").prefix(2).joined(separator: ".")
            if let current = newest[minor], !GoInstalls.isNewer(install.version, than: current.version) { continue }
            newest[minor] = install
        }
        return newest.values.sorted { GoInstalls.isNewer($0.version, than: $1.version) }
    }
}
