import Darwin
import Foundation

/// One handshaken connection to gobid on a single channel.
public final class GobiSession: @unchecked Sendable {
    private let connection: UnixConnection
    private var decoder = FrameDecoder()
    private var queued: [[UInt8]] = []

    private init(connection: UnixConnection) {
        self.connection = connection
    }

    public static func connect(
        socketPath: String,
        channel: String,
        workspaceRoot: String,
        language: String? = nil,
        trusted: Bool = false,
        clientVersion: String = GobiClientVersion.current
    ) throws -> GobiSession {
        let session = GobiSession(connection: try UnixConnection(path: socketPath))
        var hello: [String: Any] = ["protocol": 1, "client_version": clientVersion, "channel": channel, "workspace_root": workspaceRoot]
        if trusted { hello["trusted"] = true }
        if let language { hello["language"] = language }
        try session.send(Array(try JSONSerialization.data(withJSONObject: hello)))

        guard let answer = try session.nextMessage(),
              let reply = try JSONSerialization.jsonObject(with: Data(answer)) as? [String: Any] else {
            throw ConnectionError.closed
        }
        guard reply["ok"] as? Bool == true else {
            throw ConnectionError.rejected(reply["error"] as? String ?? "unknown reason")
        }
        return session
    }

    public func send(_ payload: [UInt8]) throws {
        try connection.write(frame(payload))
    }

    /// Blocks for the next message; nil when gobid closed the connection.
    public func nextMessage() throws -> [UInt8]? {
        while queued.isEmpty {
            guard let chunk = try connection.read() else { return nil }
            queued = try decoder.feed(chunk)
        }
        return queued.removeFirst()
    }

    public func close() { connection.close() }
}

/// Finds, and if needed starts, the gobid daemon.
public enum Gobid {
    /// The directory gobid uses by default; mirrors `ipc.SocketDir(os.TempDir())` in the Go core.
    public static func defaultSocketDirectory() -> String {
        var base = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
        if base.isEmpty { base = "/tmp" }
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let name = "gobi-\(geteuid())"
        let preferred = "\(base)/\(name)"
        // sun_path is 104 bytes on macOS; the Go side keeps the whole socket path under 100.
        return "\(preferred)/gobid.sock".utf8.count > 100 ? "/tmp/\(name)" : preferred
    }

    public static func defaultSocketPath() -> String { defaultSocketDirectory() + "/gobid.sock" }

    public static func locateBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = environment["GOBID_PATH"] { candidates.append(explicit) }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("gobid").path)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(directory)/gobid") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Connects to the running daemon, starting one first when none answers.
    public static func connect(
        channel: String,
        workspaceRoot: String,
        language: String? = nil,
        trusted: Bool = false,
        autostart: Bool = true
    ) throws -> GobiSession {
        let socketPath = defaultSocketPath()
        func attempt() throws -> GobiSession {
            try GobiSession.connect(socketPath: socketPath, channel: channel, workspaceRoot: workspaceRoot, language: language, trusted: trusted)
        }
        do { return try attempt() } catch let error as ConnectionError {
            guard autostart, case .system(_, let code) = error, code == ENOENT || code == ECONNREFUSED else { throw error }
        }

        guard let binary = locateBinary() else {
            throw ConnectionError.rejected("gobid is not running and was not found; set GOBID_PATH")
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: binary)
        daemon.arguments = ["serve"]
        daemon.standardInput = FileHandle.nullDevice
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()

        var lastError: Error = ConnectionError.closed
        for _ in 0 ..< 100 {
            do { return try attempt() } catch { lastError = error }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw lastError
    }
}
