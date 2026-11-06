import Foundation
import GobiModel

public struct ProjectInfo: Equatable, Sendable {
    public var root: String
    public var kind: ProjectKind
    public var modulePath: String
}

public struct NewProjectRequest: Sendable {
    public var template: String
    public var name: String
    public var location: String
    public var modulePath: String
    public var goVersion: String
    public var gitInit: Bool
    public var sampleTest: Bool
    public var scaffold: Bool
    /// A folder holding a go.work to add the module to; empty for none.
    public var workDir: String

    public init(template: String, name: String, location: String, modulePath: String = "", goVersion: String = "", gitInit: Bool = true,
                sampleTest: Bool = false, scaffold: Bool = true, workDir: String = "") {
        self.template = template
        self.name = name
        self.location = location
        self.modulePath = modulePath
        self.goVersion = goVersion
        self.gitInit = gitInit
        self.sampleTest = sampleTest
        self.scaffold = scaffold
        self.workDir = workDir
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case server(String)
    case badReply

    public var description: String {
        switch self {
        case .server(let message): return message
        case .badReply: return "unexpected reply from gobid"
        }
    }
}

/// Project requests to gobid over the control channel. Calls block, so run them off the main thread.
public final class ControlClient: @unchecked Sendable {
    private let session: GobiSession
    private var nextID: UInt64 = 1

    public init(session: GobiSession) { self.session = session }

    public static func connect() throws -> ControlClient {
        ControlClient(session: try Gobid.connect(channel: "control", workspaceRoot: ""))
    }

    public func close() { session.close() }

    public func newProject(_ request: NewProjectRequest) throws -> ProjectInfo {
        try call("project/new") { Self.write(request, into: &$0) }
    }

    /// The files `newProject` would write for this request, relative to the project folder. Writes nothing.
    public func preview(_ request: NewProjectRequest) throws -> [String] {
        try callRaw("project/preview") { Self.write(request, into: &$0) }.result.filter { $0.number == 4 }.map(\.string)
    }

    /// The templates of the New Project dialog as gobid lists them, in dialog order (project/templates).
    public func templates() throws -> [ProjectTemplate] {
        ProjectTemplate.parse(try callRaw("project/templates") { _ in }.result)
    }

    private static func write(_ request: NewProjectRequest, into writer: inout WireWriter) {
        writer.string(1, request.template)
        writer.string(2, request.name)
        writer.string(3, request.location)
        writer.string(4, request.modulePath)
        writer.string(5, request.goVersion)
        writer.bool(6, request.gitInit)
        writer.bool(7, request.sampleTest)
        writer.bool(8, request.scaffold)
        writer.string(9, request.workDir)
    }

    public func clone(url: String, location: String, name: String = "") throws -> ProjectInfo {
        try call("project/clone") {
            $0.string(1, url)
            $0.string(2, location)
            $0.string(3, name)
        }
    }

    public func importFolder(path: String, modulePath: String = "") throws -> ProjectInfo {
        try call("project/import") {
            $0.string(1, path)
            $0.string(2, modulePath)
        }
    }

    public func open(path: String) throws -> ProjectInfo {
        try call("project/open") { $0.string(1, path) }
    }

    /// Which of the tools Gobi uses are installed.
    public func toolsCheck() throws -> [ToolStatus] {
        ToolStatus.parse(try callRaw("tools/check") { _ in }.result)
    }

    /// Installs a tool with `go install`. Takes a while and uses the network: ask the user first.
    public func toolsInstall(_ name: String) throws {
        _ = try callRaw("tools/install") { $0.string(1, name) }
    }

    /// The Go releases that can be installed (newest patch of each recent minor), newest first. Needs the network.
    public func toolchainAvailable() throws -> [String] {
        try callRaw("toolchain/available") { _ in }.result.filter { $0.number == 1 }.map(\.string)
    }

    /// Downloads a Go version into ~/sdk. Slow and uses the network: ask the user first.
    public func toolchainInstall(_ version: String) throws {
        _ = try callRaw("toolchain/install") { $0.string(1, version) }
    }

    /// Reads a .pprof file (core/internal/pprof): sample types, call tree and top table. `sampleIndex` nil uses the profile's default.
    public func profileLoad(path: String, sampleIndex: Int? = nil) throws -> ProfileData {
        try ProfileData.parse(try callRaw("profile/load") { $0.string(1, path); $0.string(2, sampleIndex.map(String.init) ?? "") }.result)
    }

    /// Per-line cost of one function of a profile (profile/lines).
    public func profileLines(path: String, sampleIndex: Int?, function: String) throws -> ProfileLines {
        try ProfileLines.parse(try callRaw("profile/lines") { $0.string(1, path); $0.string(2, sampleIndex.map(String.init) ?? ""); $0.string(3, function) }.result)
    }

    /// Compares two profile files per function (profile/diff). `type` empty uses the base profile's default sample type.
    public func profileDiff(base: String, other: String, type: String = "") throws -> ProfileDiff {
        try ProfileDiff.parse(try callRaw("profile/diff") { $0.string(1, base); $0.string(2, other); $0.string(3, type) }.result)
    }

    /// Downloads a profile from a program on this machine that serves net/http/pprof, and writes it to `output` (.pprof).
    public func profileCapture(address: String, kind: String, seconds: Int, output: String) throws {
        _ = try callRaw("profile/capture") { $0.string(1, address); $0.string(2, kind); $0.string(3, String(seconds)); $0.string(4, output) }
    }

    /// The shells /etc/shells lists, and the login shell ($SHELL of gobid).
    public func terminalShells() throws -> (shells: [String], login: String) {
        let result = try callRaw("terminal/shells") { _ in }.result
        return (result.filter { $0.number == 1 }.map(\.string), result.first { $0.number == 2 }?.string ?? "")
    }

    public struct DaemonStatus: Equatable, Sendable {
        public let pid: Int
        public let runtime: String
        public let logLevel: String
        public let startedAt: Int
    }

    /// What gobid reports about itself: process id, Go runtime, log level and start time.
    public func daemonStatus() throws -> DaemonStatus {
        let fields = try callRaw("daemon/status") { _ in }.result
        func number(_ n: Int) -> Int { Int(fields.first { $0.number == n }?.uint ?? 0) }
        func text(_ n: Int) -> String { fields.first { $0.number == n }?.string ?? "" }
        return DaemonStatus(pid: number(1), runtime: text(2), logLevel: text(3), startedAt: number(4))
    }

    /// `debug`, `info`, `warn` or `error`.
    public func setLogLevel(_ level: String) throws { _ = try callRaw("daemon/loglevel") { $0.string(1, level) } }

    /// Shuts gobid down; the next connection starts a new one.
    public func stopDaemon() throws { _ = try callRaw("daemon/stop") { _ in } }

    /// Find in Files over a project folder. Blocks; run it off the main thread. A replacement, when given, is worked out for every hit.
    public func searchFiles(root: String, query: String, regex: Bool, caseSensitive: Bool, wholeWord: Bool, include: [String], replacement: String?, limit: Int = 0) throws -> SearchResults {
        let reply = try callRaw("search/files") {
            $0.string(1, query)
            $0.bool(2, regex)
            $0.bool(3, caseSensitive)
            $0.bool(4, wholeWord)
            $0.string(5, replacement ?? "")
            $0.bool(6, replacement != nil)
            for glob in include { $0.string(7, glob) }
            $0.uint(8, UInt64(limit))
            $0.string(9, root)
        }
        return try SearchResults.parse(reply.result)
    }

    private func callRaw(_ method: String, _ params: (inout WireWriter) -> Void) throws -> ControlWire.Reply {
        let id = nextID
        nextID += 1
        try session.send(ControlWire.request(id: id, method: method, params: params))
        guard let payload = try session.nextMessage() else { throw ControlError.badReply }
        let reply = try ControlWire.parseReply(payload)
        if let failure = reply.failure { throw ControlError.server(failure) }
        guard reply.id == id else { throw ControlError.badReply }
        return reply
    }

    private func call(_ method: String, _ params: (inout WireWriter) -> Void) throws -> ProjectInfo {
        let reply = try callRaw(method, params)
        var root = "", kind = "", modulePath = ""
        for field in reply.result {
            switch field.number {
            case 1: root = field.string
            case 2: kind = field.string
            case 3: modulePath = field.string
            default: break
            }
        }
        guard !root.isEmpty, let projectKind = ProjectKind(rawValue: kind) else { throw ControlError.badReply }
        return ProjectInfo(root: root, kind: projectKind, modulePath: modulePath)
    }
}
