import AppKit
import GobiClient
import GobiModel

/// Version facts for the log and Copy Diagnostics.
enum AppInfo {
    static var version: String { GobiClientVersion.current }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }
    /// Set by a build that stamps `GobiCommit` into Info.plist; "unknown" for a plain `swift build`.
    static var commit: String { Bundle.main.object(forInfoDictionaryKey: "GobiCommit") as? String ?? "unknown" }
    static var versionText: String { "\(version) (\(build))" }

    static var architecture: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}

/// Start-up logging, the crash marker and the Help menu's two log items.
enum LogSupport {
    static var isSelfTest: Bool { CommandLine.arguments.contains { $0.hasPrefix("--selftest") } }

    /// First thing at launch. Returns true when the last run did not exit cleanly and the user should be told.
    @discardableResult
    static func start() -> Bool {
        AppLog.installCrashHandlers(version: AppInfo.versionText)
        let log = AppLog.shared
        let system = ProcessInfo.processInfo.operatingSystemVersion
        log.logInfo("Gobi starting: version \(AppInfo.version), build \(AppInfo.build), commit \(AppInfo.commit), macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion), \(AppInfo.architecture)")
        guard !isSelfTest else { return false }   // a self-test leaves no marker
        let existed = AppLog.markRunning()
        let crashed = CrashNotice.previousRunEndedBadly(markerExists: existed, selfTest: false)
        if crashed { log.logWarn("previous run did not exit cleanly") }
        return crashed
    }

    static func quit() {
        AppLog.shared.logInfo("Gobi quit cleanly")
        if !isSelfTest { AppLog.markExited() }
    }

    static func revealLogs() {
        try? FileManager.default.createDirectory(atPath: AppLog.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.directory))
    }

    /// The last 64 KB of a file, as text; empty when it cannot be read.
    private static func tail(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Foundation.Data(), as: UTF8.self)
    }

    private static func gobidVersion() -> String {
        guard let binary = Gobid.locateBinary() else { return "" }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Blocking: asks gobid for tools and status. Call off the main thread.
    static func diagnosticsText() -> String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var tools: [ToolStatus] = []
        var status: ControlClient.DaemonStatus?
        if let client = try? ControlClient.connect() {
            tools = (try? client.toolsCheck()) ?? []
            status = try? client.daemonStatus()
            client.close()
        }
        return Diagnostics.report(Diagnostics.Input(
            gobiVersion: AppInfo.version, gobiBuild: AppInfo.build, gobiCommit: AppInfo.commit, gobidVersion: gobidVersion(),
            macOS: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)", architecture: AppInfo.architecture,
            tools: tools, daemonPid: status?.pid, daemonStartedUnix: status?.startedAt,
            appLog: tail(of: AppLog.path), daemonLog: tail(of: AppLog.daemonLogPath)))
    }

    static func copyDiagnostics(done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = diagnosticsText()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                done?()
            }
        }
    }
}
