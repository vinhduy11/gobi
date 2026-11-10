/// `key=value` lines, the storage form of the settings structs below.
private enum Lines {
    static func parse(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let cut = line.firstIndex(of: "=") else { continue }
            map[String(line[line.startIndex ..< cut])] = String(line[line.index(after: cut)...])
        }
        return map
    }

    static func nearest(_ value: Int, in list: [Int]) -> Int { list.min { abs($0 - value) < abs($1 - value) } ?? value }
}

/// Settings > General.
public struct GeneralSettings: Equatable, Sendable {
    public enum Launch: String, Sendable { case reopenLast, welcome }
    public static let recentLimits = [5, 10, 20]
    public var onLaunch = Launch.reopenLast
    public var recentLimit = 10
    /// Ask before quitting while files have unsaved changes or a run or debug session is going.
    public var confirmQuit = true
    /// Offer pre-release updates (alpha, beta, rc). nil until chosen: then a pre-release build does and a stable one does not.
    public var includePrereleases: Bool?
    public init() {}

    public func validated() -> GeneralSettings {
        var s = self
        s.recentLimit = Lines.nearest(recentLimit, in: Self.recentLimits)
        return s
    }

    public func encoded() -> String {
        var text = "onLaunch=\(onLaunch.rawValue)\nrecentLimit=\(recentLimit)\nconfirmQuit=\(confirmQuit)"
        if let includePrereleases { text += "\nincludePrereleases=\(includePrereleases)" }
        return text
    }

    public static func decodeOrDefault(_ text: String) -> GeneralSettings {
        let map = Lines.parse(text)
        var s = GeneralSettings()
        if let v = map["onLaunch"].flatMap(Launch.init(rawValue:)) { s.onLaunch = v }
        if let v = map["recentLimit"].flatMap({ Int($0) }) { s.recentLimit = v }
        if let v = map["confirmQuit"] { s.confirmQuit = v == "true" }
        if let v = map["includePrereleases"] { s.includePrereleases = v == "true" }
        return s.validated()
    }
}

/// Settings > Terminal.
public struct TerminalSettings: Equatable, Sendable {
    public enum Cursor: String, Sendable { case block, bar, underline }
    public enum Bell: String, Sendable { case sound, off }
    public enum StartFolder: String, Sendable {
        case project, home
        /// The folder a new terminal starts in; the project when there is no home to offer.
        public func folder(project: String, home: String) -> String { self == .home && !home.isEmpty ? home : project }
    }
    public static let fontSizes = [11, 12, 13, 14, 16, 18]
    public static let scrollbackLines = [1_000, 5_000, 10_000, 50_000]
    public var fontName = "SF Mono"
    public var fontSize = 12
    public var cursor = Cursor.block
    public var blink = true
    public var optionAsMeta = false
    public var bell = Bell.sound
    public var scrollback = 10_000
    public var startIn = StartFolder.project
    public var copyOnSelect = false
    public init() {}

    public func validated() -> TerminalSettings {
        var s = self
        s.fontSize = Lines.nearest(fontSize, in: Self.fontSizes)
        s.scrollback = Lines.nearest(scrollback, in: Self.scrollbackLines)
        return s
    }

    public func encoded() -> String { "fontName=\(fontName)\nfontSize=\(fontSize)\ncursor=\(cursor.rawValue)\nblink=\(blink)\noptionAsMeta=\(optionAsMeta)\nbell=\(bell.rawValue)\nscrollback=\(scrollback)\nstartIn=\(startIn.rawValue)\ncopyOnSelect=\(copyOnSelect)" }

    public static func decodeOrDefault(_ text: String) -> TerminalSettings {
        let map = Lines.parse(text)
        var s = TerminalSettings()
        if let v = map["fontName"], !v.isEmpty { s.fontName = v }
        if let v = map["fontSize"].flatMap({ Int($0) }) { s.fontSize = v }
        if let v = map["cursor"].flatMap(Cursor.init(rawValue:)) { s.cursor = v }
        if let v = map["blink"] { s.blink = v == "true" }
        if let v = map["optionAsMeta"] { s.optionAsMeta = v == "true" }
        if let v = map["bell"].flatMap(Bell.init(rawValue:)) { s.bell = v }
        if let v = map["scrollback"].flatMap({ Int($0) }) { s.scrollback = v }
        if let v = map["startIn"].flatMap(StartFolder.init(rawValue:)) { s.startIn = v }
        if let v = map["copyOnSelect"] { s.copyOnSelect = v == "true" }
        return s.validated()
    }
}

/// Settings > Git.
public struct GitSettings: Equatable, Sendable {
    public var showColours = true
    public var showGutterMarks = true
    public var refreshOnFocus = true
    public var warnLongSubject = true
    /// The git program (absolute path); empty is the git on PATH.
    public var gitPath = ""
    /// Minutes between automatic fetches; 0 never.
    public var fetchMinutes = 0
    public static let fetchIntervals = [0, 5, 10, 30]
    public init() {}

    public func encoded() -> String {
        "showColours=\(showColours)\nshowGutterMarks=\(showGutterMarks)\nrefreshOnFocus=\(refreshOnFocus)\nwarnLongSubject=\(warnLongSubject)\ngitPath=\(ToolPath.clean(gitPath))\nfetchMinutes=\(fetchMinutes)"
    }

    public static func decodeOrDefault(_ text: String) -> GitSettings {
        let map = Lines.parse(text)
        var s = GitSettings()
        if let v = map["showColours"] { s.showColours = v == "true" }
        if let v = map["showGutterMarks"] { s.showGutterMarks = v == "true" }
        if let v = map["refreshOnFocus"] { s.refreshOnFocus = v == "true" }
        if let v = map["warnLongSubject"] { s.warnLongSubject = v == "true" }
        if let v = map["gitPath"] { s.gitPath = ToolPath.clean(v) }
        if let v = map["fetchMinutes"].flatMap({ Int($0) }) { s.fetchMinutes = Lines.nearest(v, in: fetchIntervals) }
        return s
    }

    public static let subjectLimit = 50

    /// A note for the commit sheet when the first line of the message is long.
    public static func subjectWarning(for message: String, enabled: Bool) -> String? {
        guard enabled, let first = message.split(separator: "\n", omittingEmptySubsequences: false).first, first.count > subjectLimit else { return nil }
        return "The first line is \(first.count) characters; keep it under \(subjectLimit)."
    }
}

/// Shortcuts the user changed, by menu item ("Run ▸ Run Tests"). Only the changes are kept; the rest follow the menu spec.
public struct KeymapOverrides: Equatable, Sendable {
    private var changes: [String: String] = [:]
    public init() {}

    public func shortcut(for item: String, default fallback: String) -> String { changes[item] ?? fallback }
    public func isCustom(_ item: String) -> Bool { changes[item] != nil }
    public mutating func set(_ shortcut: String, for item: String) { changes[item] = shortcut }
    public mutating func reset(_ item: String) { changes[item] = nil }
    public mutating func resetAll() { changes = [:] }

    /// The item that already has `shortcut` (after applying the changes), if it is not the one being changed.
    public func conflict(for shortcut: String, changing item: String, among all: [(item: String, shortcut: String)]) -> String? {
        guard !shortcut.isEmpty else { return nil }
        return all.first { $0.item != item && self.shortcut(for: $0.item, default: $0.shortcut) == shortcut }?.item
    }

    public func encoded() -> String { changes.keys.sorted().map { $0 + "\u{1F}" + (changes[$0] ?? "") }.joined(separator: "\n") }

    public static func decode(_ text: String) -> KeymapOverrides {
        var map = KeymapOverrides()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { map.set(parts[1], for: parts[0]) }
        }
        return map
    }
}

/// Moves shortcuts stored under the item names of the menu bar before the Debug menu was merged into Run (and a few renames)
/// to the current names. Run once: the caller keeps the version it last migrated to.
public enum KeymapMigration {
    public static let currentVersion = 1

    /// Old item id to current item id.
    public static let renames: [String: String] = [
        "Debug ▸ Start Debugging": "Run ▸ Debug",
        "Debug ▸ Stop": "Run ▸ Stop",
        "Debug ▸ Restart": "Run ▸ Debugging Actions ▸ Restart",
        "Debug ▸ Continue": "Run ▸ Resume Program",
        "Debug ▸ Step Over": "Run ▸ Step Over",
        "Debug ▸ Step Into": "Run ▸ Step Into",
        "Debug ▸ Step Out": "Run ▸ Step Out",
        "Debug ▸ Toggle Breakpoint": "Run ▸ Toggle Line Breakpoint",
        "Debug ▸ Add Conditional Breakpoint…": "Run ▸ Add Conditional Breakpoint…",
        "Debug ▸ Attach to Process…": "Run ▸ Attach to Process…",
        "Debug ▸ Show Goroutines": "Run ▸ Show Goroutines",
        "Edit ▸ Find ▸ Find in Files…": "Edit ▸ Find in Files…",
        "Window ▸ Show Next Tab": "Window ▸ Editor Tabs ▸ Show Next Tab",
        "Window ▸ Show Previous Tab": "Window ▸ Editor Tabs ▸ Show Previous Tab",
    ]

    /// A shortcut already set under the new name wins over one moved from the old name.
    public static func migrate(_ overrides: KeymapOverrides, from version: Int) -> KeymapOverrides {
        guard version < currentVersion else { return overrides }
        var result = overrides
        for (old, new) in renames where overrides.isCustom(old) {
            if !result.isCustom(new) { result.set(overrides.shortcut(for: old, default: ""), for: new) }
            result.reset(old)
        }
        return result
    }
}

public enum ShortcutGlyphs {
    /// "⌥⌘R" from a key and modifiers, in the order macOS shows them (⌃⌥⇧⌘). A letter, digit or symbol needs ⌘, ⌃ or ⌥; a function
    /// key (F1 to F12) stands alone. Nil when the key cannot be a shortcut.
    public static func make(key: String, command: Bool, option: Bool, control: Bool, shift: Bool) -> String? {
        var name: String
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xF704 ... 0xF70F).contains(scalar.value) {
            name = "F\(Int(scalar.value) - 0xF704 + 1)"
        } else if key.count == 1, let character = key.first, !character.isWhitespace {
            guard command || control || option else { return nil }
            name = key.uppercased()
        } else {
            return nil
        }
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }
}

/// A program the user points Gobi at (git, gopls): empty means the one on PATH, otherwise an absolute path.
public enum ToolPath {
    public static func clean(_ path: String) -> String {
        var text = Substring(path)
        while text.first == " " { text = text.dropFirst() }
        while text.last == " " { text = text.dropLast() }
        guard text.first == "/", !text.contains("\n") else { return "" }
        return String(text)
    }
}

/// Settings > Advanced values that are real: the gopls program and the line length over which a file opens read-only.
public struct AdvancedSettings: Equatable, Sendable {
    public static let lineLimits = [100_000, 250_000, 550_000, 1_000_000]
    public var goplsPath = ""
    public var lineLimit = 550_000
    public init() {}

    public func encoded() -> String { "goplsPath=\(ToolPath.clean(goplsPath))\nlineLimit=\(lineLimit)" }

    public static func decodeOrDefault(_ text: String) -> AdvancedSettings {
        let map = Lines.parse(text)
        var s = AdvancedSettings()
        if let v = map["goplsPath"] { s.goplsPath = ToolPath.clean(v) }
        if let v = map["lineLimit"].flatMap({ Int($0) }) { s.lineLimit = Lines.nearest(v, in: lineLimits) }
        return s
    }

    /// "550,000 characters"
    public static func lineLimitTitle(_ limit: Int) -> String {
        let digits = Array(String(limit))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out += "," }
            out.append(digit)
        }
        return out + " characters"
    }
}

public enum QuitConfirmation {
    /// What to tell the person before quitting, or nil when quitting loses nothing (or the check is switched off).
    public static func message(unsavedFiles: Int, runningTasks: Int, enabled: Bool) -> String? {
        guard enabled, unsavedFiles > 0 || runningTasks > 0 else { return nil }
        var parts: [String] = []
        if unsavedFiles > 0 { parts.append(unsavedFiles == 1 ? "1 file has unsaved changes." : "\(unsavedFiles) files have unsaved changes.") }
        if runningTasks > 0 { parts.append(runningTasks == 1 ? "1 run or debug session is still going." : "\(runningTasks) runs or debug sessions are still going.") }
        return parts.joined(separator: " ")
    }
}

public enum AutoFetch {
    public static func isDue(minutes: Int, secondsSinceLast: Int) -> Bool { minutes > 0 && secondsSinceLast >= minutes * 60 }
}
