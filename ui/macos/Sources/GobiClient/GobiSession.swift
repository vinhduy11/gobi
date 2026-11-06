import Darwin
import Foundation
import GobiModel

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
        goRoot: String = "",
        shell: String = "",
        tool: String = "",
        trusted: Bool = false,
        clientVersion: String = GobiClientVersion.current
    ) throws -> GobiSession {
        let session = GobiSession(connection: try UnixConnection(path: socketPath))
        try session.send(Handshake.encodeHello(clientVersion: clientVersion, channel: channel, workspaceRoot: workspaceRoot, trusted: trusted, language: language, goRoot: goRoot, shell: shell, tool: tool))

        guard let answer = try session.nextMessage() else { throw ConnectionError.closed }
        let reply = try Handshake.decodeReply(answer)
        guard reply.ok else { throw ConnectionError.rejected(reply.error.isEmpty ? "unknown reason" : reply.error) }
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

    private static let staleLock = NSLock()
    nonisolated(unsafe) private static var staleChecked = false

    /// The first time this process connects: when the running gobid started before the gobid file next to the app was written
    /// (an update), asks it to stop so that the connection below starts the new one. Never touches a daemon that is newer.
    private static func replaceStaleDaemonOnce(socketPath: String) {
        staleLock.lock()
        let first = !staleChecked
        staleChecked = true
        staleLock.unlock()
        guard first, let binary = locateBinary(),
              let modified = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date,
              let session = try? GobiSession.connect(socketPath: socketPath, channel: "control", workspaceRoot: "")
        else { return }
        let client = ControlClient(session: session)
        defer { client.close() }
        guard let status = try? client.daemonStatus(), DaemonFreshness.isStale(startedAt: status.startedAt, binaryModified: Int(modified.timeIntervalSince1970)) else { return }
        try? client.stopDaemon()
        // Wait for the old daemon to let go of the socket so that the new one can take it.
        for _ in 0 ..< 60 {
            if (try? GobiSession.connect(socketPath: socketPath, channel: "control", workspaceRoot: "")) == nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Connects to the running daemon, starting one first when none answers.
    public static func connect(
        channel: String,
        workspaceRoot: String,
        language: String? = nil,
        goRoot: String = "",
        shell: String = "",
        tool: String = "",
        trusted: Bool = false,
        autostart: Bool = true
    ) throws -> GobiSession {
        let socketPath = defaultSocketPath()
        if autostart { replaceStaleDaemonOnce(socketPath: socketPath) }
        func attempt() throws -> GobiSession {
            try GobiSession.connect(socketPath: socketPath, channel: channel, workspaceRoot: workspaceRoot, language: language, goRoot: goRoot, shell: shell, tool: tool, trusted: trusted)
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
