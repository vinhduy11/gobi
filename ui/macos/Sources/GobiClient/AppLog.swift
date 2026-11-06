import Darwin
import Foundation
import GobiModel

/// Gobi's own log, `gobi.log` in the logs folder (docs/architect/logging.md). Thread-safe; never throws and never crashes when
/// the disk is full or the folder is missing: a line that cannot be written is dropped.
public final class AppLog: @unchecked Sendable {
    public static let shared = AppLog()

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var size = 0
    private var directoryReady = false

    /// `~/Library/Logs/Gobi`, or `$GOBI_LOG_DIR`. A self-test with no override gets a scratch folder, never the real one.
    public static var directory: String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GOBI_LOG_DIR"], !override.isEmpty { return override }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) {
            let scratch = NSTemporaryDirectory() + "gobi-selftest-logs"
            setenv("GOBI_LOG_DIR", scratch, 1)   // the daemon the app starts inherits it
            return scratch
        }
        return NSHomeDirectory() + "/Library/Logs/Gobi"
    }

    public static var path: String { directory + "/gobi.log" }
    public static var daemonLogPath: String { directory + "/gobid.log" }
    static var markerPath: String { directory + "/running" }

    public func logInfo(_ message: String) { write(.info, message) }
    public func logWarn(_ message: String) { write(.warn, message) }
    public func logError(_ message: String) { write(.error, message) }

    public func write(_ level: LogLevel, _ message: String) {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let text = LogFormat.line(unixMillis: millis, level: level, message: LogRedaction.paths(message)) + "\n"
        append(Array(text.utf8))
    }

    private func append(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return }
        if LogFormat.shouldRotate(currentSize: size, incoming: bytes.count, limit: LogFormat.maxBytes) { rotate() }
        guard descriptor >= 0 else { return }
        let written = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if written > 0 { size += written }
    }

    /// Called with the lock held.
    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        if !directoryReady {
            try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directoryReady = true
        }
        let opened = open(Self.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard opened >= 0 else { directoryReady = false; return false }
        descriptor = opened
        FatalHandler.descriptor = opened
        var fileStat = stat()
        size = fstat(opened, &fileStat) == 0 ? Int(fileStat.st_size) : 0
        return true
    }

    /// Called with the lock held: gobi.log becomes gobi.log.1, .1 becomes .2, ... and the oldest goes.
    private func rotate() {
        close(descriptor)
        descriptor = -1
        FatalHandler.descriptor = -1
        let base = Self.path
        unlink("\(base).\(LogFormat.keep)")
        for number in stride(from: LogFormat.keep - 1, through: 1, by: -1) { rename("\(base).\(number)", "\(base).\(number + 1)") }
        rename(base, "\(base).1")
        _ = openIfNeeded()
    }

    // MARK: Run marker

    /// Creates the `running` marker and says whether one was already there (the last run did not quit cleanly).
    public static func markRunning() -> Bool {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existed = FileManager.default.fileExists(atPath: markerPath)
        FileManager.default.createFile(atPath: markerPath, contents: Data(String(getpid()).utf8), attributes: [.posixPermissions: 0o600])
        return existed
    }

    public static func markExited() { try? FileManager.default.removeItem(atPath: markerPath) }

    public static var markerExists: Bool { FileManager.default.fileExists(atPath: markerPath) }

    // MARK: Crashes

    /// Logs uncaught Objective-C exceptions and fatal signals. Call once, early. `version` goes into the fatal line.
    public static func installCrashHandlers(version: String) {
        shared.lock.lock()
        _ = shared.openIfNeeded()   // the descriptor must be ready before any crash
        shared.lock.unlock()
        NSSetUncaughtExceptionHandler { exception in
            AppLog.shared.logError("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            for symbol in exception.callStackSymbols { AppLog.shared.logError("  \(symbol)") }
        }
        FatalHandler.install(version: version)
    }
}

/// The fatal-signal path. Everything the handler touches is prepared before a crash: raw buffers and a plain descriptor, so the
/// handler needs only write(2), signal(2) and raise(2), which are async-signal-safe.
private enum FatalHandler {
    static var descriptor: Int32 = -1
    private static let slots = 32
    private static let lines = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: slots)
    private static let lengths = UnsafeMutablePointer<Int>.allocate(capacity: slots)

    static func install(version: String) {
        lines.initialize(repeating: nil, count: slots)
        lengths.initialize(repeating: 0, count: slots)
        for number in FatalSignal.handled where Int(number) < slots {
            let lineBytes = Array(FatalSignal.line(signal: number, version: version).utf8)
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: lineBytes.count)
            storage.initialize(from: lineBytes, count: lineBytes.count)
            lines[Int(number)] = storage
            lengths[Int(number)] = lineBytes.count
            signal(number) { received in
                let slot = Int(received)
                if slot < FatalHandler.slots, let line = FatalHandler.lines[slot], FatalHandler.descriptor >= 0 {
                    _ = write(FatalHandler.descriptor, line, FatalHandler.lengths[slot])
                }
                signal(received, SIG_DFL)   // macOS still writes its own crash report
                raise(received)
            }
        }
    }
}
