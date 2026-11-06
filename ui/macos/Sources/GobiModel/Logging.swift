// The pure parts of Gobi's own log (docs/architect/logging.md): line format, rotation decision, path redaction,
// the crash marker decision, the fatal-signal line and the Copy Diagnostics text. GobiClient.AppLog does the file work.

public enum LogLevel: String, Sendable {
    case info = "INFO", warn = "WARN", error = "ERROR"
}

public enum LogFormat {
    public static let maxBytes = 2 * 1024 * 1024
    /// Old files kept: gobi.log.1 ... gobi.log.4.
    public static let keep = 4

    private static func pad(_ number: Int, _ width: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// `2026-11-06T10:15:30.123Z`, UTC. A negative time is shown as the epoch.
    public static func timestamp(unixMillis: Int64) -> String {
        let millis = max(0, unixMillis)
        let seconds = millis / 1000
        let days = seconds / 86_400
        let secondOfDay = Int(seconds % 86_400)
        // Civil date from a day count (Howard Hinnant's algorithm).
        let shifted = days + 719_468
        let era = shifted / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * monthIndex + 2) / 5 + 1)
        let month = Int(monthIndex < 10 ? monthIndex + 3 : monthIndex - 9)
        let year = Int(yearOfEra + era * 400) + (month <= 2 ? 1 : 0)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(secondOfDay / 3600, 2)):\(pad(secondOfDay / 60 % 60, 2)):\(pad(secondOfDay % 60, 2)).\(pad(Int(millis % 1000), 3))Z"
    }

    /// One log line, without the trailing newline. Line breaks in the message become spaces.
    public static func line(unixMillis: Int64, level: LogLevel, message: String) -> String {
        let flat = String(message.map { $0 == "\n" || $0 == "\r" || $0 == "\r\n" ? " " : $0 })
        return "\(timestamp(unixMillis: unixMillis)) \(level.rawValue) \(flat)"
    }

    /// True when appending `incoming` bytes would pass `limit`. An empty file is never rotated.
    public static func shouldRotate(currentSize: Int, incoming: Int, limit: Int) -> Bool {
        currentSize > 0 && currentSize + incoming > limit
    }
}

public enum LogRedaction {
    /// Every absolute path in `text` shrinks to its last element, so a log names a folder or file but not where it is.
    public static func paths(_ text: String) -> String {
        let characters = Array(text)
        let startMarks: Set<Character> = [" ", "\t", "\"", "'", "=", "(", ":", "["]
        let endMarks: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", ")", ",", ";"]
        var out = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "/", index == 0 || startMarks.contains(characters[index - 1]) else {
                out.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, !endMarks.contains(characters[end]) { end += 1 }
            while end > index + 1, characters[end - 1] == ":" { end -= 1 }
            let parts = characters[index ..< end].split(separator: "/", omittingEmptySubsequences: true)
            out += parts.last.map { String($0) } ?? "/"
            index = end
        }
        return out
    }
}

public enum CrashNotice {
    /// A `running` marker left over from the last run means it did not quit cleanly. Self-tests never show the notice.
    public static func previousRunEndedBadly(markerExists: Bool, selfTest: Bool) -> Bool { markerExists && !selfTest }
}

public enum FatalSignal {
    /// SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP on macOS.
    public static let handled: [Int32] = [11, 6, 10, 4, 8, 5]

    public static func line(signal: Int32, version: String) -> String { "FATAL signal \(signal) Gobi \(version)\n" }
}

public enum Diagnostics {
    public struct Input {
        public var gobiVersion: String, gobiBuild: String, gobiCommit: String
        public var gobidVersion: String
        public var macOS: String, architecture: String
        public var tools: [ToolStatus]
        public var daemonPid: Int?
        public var daemonStartedUnix: Int?
        public var appLog: String, daemonLog: String

        public init(gobiVersion: String, gobiBuild: String, gobiCommit: String, gobidVersion: String, macOS: String, architecture: String,
                    tools: [ToolStatus], daemonPid: Int?, daemonStartedUnix: Int?, appLog: String, daemonLog: String) {
            self.gobiVersion = gobiVersion; self.gobiBuild = gobiBuild; self.gobiCommit = gobiCommit; self.gobidVersion = gobidVersion
            self.macOS = macOS; self.architecture = architecture; self.tools = tools
            self.daemonPid = daemonPid; self.daemonStartedUnix = daemonStartedUnix; self.appLog = appLog; self.daemonLog = daemonLog
        }
    }

    public static let logLines = 60

    /// The last `lines` non-empty lines of a log.
    public static func tail(_ text: String, lines: Int) -> [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(lines))
    }

    /// The text Help > Copy Diagnostics puts on the pasteboard. Every path in it is reduced to its last element.
    public static func report(_ input: Input) -> String {
        var out = ["Gobi \(input.gobiVersion) (build \(input.gobiBuild), \(input.gobiCommit))"]
        out.append(input.gobidVersion.isEmpty ? "gobid: version unknown" : input.gobidVersion)
        out.append("macOS \(input.macOS), \(input.architecture)")
        out.append("")
        out.append("Tools")
        for tool in input.tools {
            out.append(tool.found ? "  \(tool.name): \(tool.version) (\(tool.path))" : "  \(tool.name): not found")
        }
        out.append("")
        if let pid = input.daemonPid {
            let started = input.daemonStartedUnix.map { ", started \(LogFormat.timestamp(unixMillis: Int64($0) * 1000))" } ?? ""
            out.append("gobid: running, pid \(pid)\(started)")
        } else {
            out.append("gobid: not running")
        }
        out.append("")
        out.append("--- gobi.log (last \(logLines) lines)")
        out += tail(input.appLog, lines: logLines)
        out.append("--- gobid.log (last \(logLines) lines)")
        out += tail(input.daemonLog, lines: logLines)
        return LogRedaction.paths(out.joined(separator: "\n") + "\n")
    }
}
