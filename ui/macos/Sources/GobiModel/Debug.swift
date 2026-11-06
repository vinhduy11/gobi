/// The lines with a breakpoint, per file path.
public struct Breakpoints: Equatable, Sendable {
    private var byPath: [String: Set<Int>] = [:]
    private var conditions: [String: [Int: String]] = [:]

    public init() {}

    public var paths: [String] { byPath.keys.sorted() }
    public var count: Int { byPath.values.reduce(0) { $0 + $1.count } }
    public func lines(in path: String) -> [Int] { (byPath[path] ?? []).sorted() }

    /// Adds the breakpoint or removes it; true when it is now set.
    @discardableResult
    public mutating func toggle(path: String, line: Int) -> Bool {
        var lines = byPath[path] ?? []
        let added = lines.insert(line).inserted
        if !added { lines.remove(line) }
        byPath[path] = lines.isEmpty ? nil : lines
        if !added { conditions[path]?[line] = nil }
        return added
    }

    public mutating func removeAll(in path: String) { byPath[path] = nil; conditions[path] = nil }

    /// Makes `line` a breakpoint that stops only when `condition` is true; an empty condition makes it a plain breakpoint again.
    public mutating func setCondition(_ condition: String, path: String, line: Int) {
        byPath[path, default: []].insert(line)
        let clean = condition.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ").trimmingSpaces()
        conditions[path, default: [:]][line] = clean.isEmpty ? nil : clean
        if conditions[path]?.isEmpty == true { conditions[path] = nil }
    }

    public func condition(path: String, line: Int) -> String? { conditions[path]?[line] }

    /// One line per file: `path=3,9`.
    public func encoded() -> String {
        var rows = paths.map { path in path + "=" + lines(in: path).map(String.init).joined(separator: ",") }
        for path in conditions.keys.sorted() {
            for line in (conditions[path] ?? [:]).keys.sorted() { rows.append("?" + path + "\u{1F}" + String(line) + "\u{1F}" + (conditions[path]?[line] ?? "")) }
        }
        return rows.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> Breakpoints {
        var result = Breakpoints()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("?") {
                let parts = line.dropFirst().split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let number = Int(parts[1]) { result.setCondition(String(parts[2]), path: String(parts[0]), line: number) }
                continue
            }
            guard let cut = line.lastIndex(of: "=") else { continue }
            let path = String(line[line.startIndex ..< cut])
            guard !path.isEmpty else { continue }
            for number in line[line.index(after: cut)...].split(separator: ",") {
                if let value = Int(number) { result.toggle(path: path, line: value) }
            }
        }
        return result
    }
}

/// One line of the call stack.
public struct DebugFrame: Equatable, Sendable {
    public let id: Int
    public let name: String
    public let path: String
    public let line: Int

    public init(id: Int, name: String, path: String, line: Int) { self.id = id; self.name = name; self.path = path; self.line = line }

    /// "(*Server).Run" for a method, "main.main" for a function: the package path is dropped, the package name kept for functions.
    public var title: String {
        let tail = name.lastIndex(of: "/").map { String(name[name.index(after: $0)...]) } ?? name
        var previous: Character?
        for index in tail.indices {
            if previous == ".", tail[index] == "(" { return String(tail[tail.index(before: index)...].dropFirst()) }
            previous = tail[index]
        }
        return tail
    }

    public var location: String {
        let file = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
        return file + ":" + String(line)
    }
}

public struct DebugVariable: Equatable, Sendable {
    public let name: String
    public let type: String
    public let value: String
    /// Non-zero when the variable has children that can be fetched.
    public let reference: Int
    public init(name: String, type: String, value: String, reference: Int) { self.name = name; self.type = type; self.value = value; self.reference = reference }
}

public enum DebugState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopped(reason: String, location: String)
    case ended(String)

    public var isActive: Bool {
        switch self {
        case .starting, .running, .stopped: return true
        case .idle, .ended: return false
        }
    }

    public var canStep: Bool { if case .stopped = self { return true } else { return false } }
    public var canPause: Bool { self == .running }

    public func statusText(project: String) -> String {
        switch self {
        case .idle: return ""
        case .starting: return "Starting the debugger…"
        case .running: return "Debugging " + project
        case .stopped(let reason, let location): return "Paused at \(reason) · \(location)"
        case .ended(let how): return "Finished · " + how
        }
    }
}

extension String {
    fileprivate func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while scalars.first == " " || scalars.first == "\t" { scalars = scalars.dropFirst() }
        while scalars.last == " " || scalars.last == "\t" { scalars = scalars.dropLast() }
        return String(scalars)
    }
}

/// A goroutine, which Delve's DAP reports as a thread.
public struct DebugThread: Equatable, Sendable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }

    /// The function a goroutine is in: "main.main" from "Goroutine 1 - User: ./main.go:13 main.main (0x10)" or from
    /// "* [Go 1] main.main (Thread 123)" (the form Delve 1.27 uses; the star marks the goroutine that is running).
    public var title: String {
        let parts = name.split(separator: " ")
        if parts.count >= 6, parts[0] == "Goroutine", parts[2] == "-" { return String(parts[5]) }
        // "[Go", "1]", "main.main": the function comes right after the part that closes the bracket.
        if let open = parts.firstIndex(of: "[Go"), let close = parts[open...].firstIndex(where: { $0.hasSuffix("]") }), parts.indices.contains(close + 1) {
            return String(parts[close + 1])
        }
        return name
    }
}

/// The expressions in the Watch list.
public struct WatchList: Equatable, Sendable {
    public private(set) var expressions: [String] = []
    public init() {}

    public mutating func add(_ expression: String) {
        let clean = expression.trimmingSpaces()
        if !clean.isEmpty, !expressions.contains(clean) { expressions.append(clean) }
    }

    public mutating func remove(at index: Int) { if expressions.indices.contains(index) { expressions.remove(at: index) } }

    public func encoded() -> String { expressions.joined(separator: "\n") }
    public static func decode(_ text: String) -> WatchList {
        var list = WatchList()
        for line in text.split(separator: "\n") { list.add(String(line)) }
        return list
    }
}

/// Values shown at the end of source lines while paused ("a = 20, b = 22").
public enum InlineValues {
    /// For each line (1-based) of the current function up to the current line that uses a local, the locals it uses.
    public static func compute(lines: [String], currentLine: Int, variables: [DebugVariable]) -> [Int: String] {
        guard currentLine >= 1, currentLine <= lines.count else { return [:] }
        let shown = variables.filter { !$0.name.hasPrefix("~") && !$0.name.isEmpty }
        var start = 0
        for index in stride(from: currentLine - 1, through: 0, by: -1) where lines[index].hasPrefix("func ") { start = index; break }
        var result: [Int: String] = [:]
        for index in start ..< currentLine {
            let used = identifiers(in: lines[index])
            var parts: [String] = []
            var seen = Set<String>()
            for name in used where !seen.contains(name) {
                guard let variable = shown.first(where: { $0.name == name }) else { continue }
                seen.insert(name)
                parts.append(variable.name + " = " + shorten(variable.value))
            }
            if !parts.isEmpty { result[index + 1] = parts.joined(separator: ", ") }
        }
        return result
    }

    private static func shorten(_ value: String) -> String { value.count > 40 ? String(value.prefix(37)) + "…" : value }

    private static func identifiers(in line: String) -> [String] {
        var names: [String] = []
        var current = ""
        for character in line {
            if character.isLetter || character.isNumber || character == "_" { current.append(character) }
            else if !current.isEmpty { names.append(current); current = "" }
        }
        if !current.isEmpty { names.append(current) }
        return names
    }
}

/// One running process in the Attach to Process list.
public struct ProcessRow: Equatable, Sendable {
    public let pid: Int
    public let name: String

    /// Reads `ps -axo pid=,comm=` output; the system's own process 1 is left out. Sorted by pid.
    public static func parse(_ output: String) -> [ProcessRow] {
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingSpaces()
            guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[trimmed.startIndex ..< space]), pid > 1 else { continue }
            let path = trimmed[space...].trimmingSpaces()
            let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
            if !name.isEmpty { rows.append(ProcessRow(pid: pid, name: name)) }
        }
        return rows.sorted { $0.pid < $1.pid }
    }

    public static func filter(_ rows: [ProcessRow], by text: String) -> [ProcessRow] {
        let needle = text.trimmingSpaces().lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(needle) || String($0.pid).contains(needle) }
    }
}

extension Substring {
    fileprivate func trimmingSpaces() -> String { String(self).trimmingSpaces() }
}
