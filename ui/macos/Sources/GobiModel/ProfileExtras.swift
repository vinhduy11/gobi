/// Per-line cost of one function (core/internal/daemon, profile/lines).
public struct ProfileLineCost: Equatable, Sendable {
    public let line: Int
    public let flat: Int
    public let cum: Int
    public init(line: Int, flat: Int, cum: Int) { self.line = line; self.flat = flat; self.cum = cum }
}

public struct ProfileLines: Equatable, Sendable {
    public var file = ""
    /// The line of the function declaration, 0 when the profile does not say.
    public var startLine = 0
    public var rows: [ProfileLineCost] = []

    public func cost(atLine line: Int) -> ProfileLineCost? { rows.first { $0.line == line } }
    public var firstLine: Int? { rows.first?.line }

    public static func parse(_ fields: [WireField]) throws -> ProfileLines {
        var lines = ProfileLines()
        for field in fields {
            if field.number == 1 { lines.file = field.string }
            if field.number == 3 { lines.startLine = Int(field.uint) }
            if field.number == 2 {
                var line = 0, flat = 0, cum = 0
                for f in try WireField.parse(field.bytes) {
                    if f.number == 1 { line = Int(f.uint) } else if f.number == 2 { flat = Int(f.uint) } else if f.number == 3 { cum = Int(f.uint) }
                }
                lines.rows.append(ProfileLineCost(line: line, flat: flat, cum: cum))
            }
        }
        return lines
    }
}

/// One function compared across two profiles.
public struct ProfileDiffRow: Equatable, Sendable {
    public let name: String
    public let baseFlat: Int
    public let newFlat: Int
    public let baseCum: Int
    public let newCum: Int
    public var flatDelta: Int { newFlat - baseFlat }
    public var cumDelta: Int { newCum - baseCum }
}

/// The answer of profile/diff: functions ordered by the size of their flat change.
public struct ProfileDiff: Equatable, Sendable {
    public var type = ""
    public var unit = ""
    public var baseTotal = 0
    public var newTotal = 0
    public var rows: [ProfileDiffRow] = []

    public static func parse(_ fields: [WireField]) throws -> ProfileDiff {
        var diff = ProfileDiff()
        for field in fields {
            switch field.number {
            case 1: diff.type = field.string
            case 2: diff.unit = field.string
            case 3: diff.baseTotal = Int(field.uint)
            case 4: diff.newTotal = Int(field.uint)
            case 5:
                var name = "", values = [0, 0, 0, 0]
                for f in try WireField.parse(field.bytes) {
                    if f.number == 1 { name = f.string } else if (2 ... 5).contains(f.number) { values[f.number - 2] = Int(f.uint) }
                }
                diff.rows.append(ProfileDiffRow(name: name, baseFlat: values[0], newFlat: values[1], baseCum: values[2], newCum: values[3]))
            default: break
            }
        }
        return diff
    }
}

extension ProfileFormat {
    /// A change as "+1.20 s", "-3 ms" or "0".
    public static func delta(_ change: Int, unit: String) -> String {
        if change == 0 { return "0" }
        return (change > 0 ? "+" : "-") + value(change > 0 ? change : -change, unit: unit)
    }
}

/// The Profiler's filter box: narrows the Top table and the flame graph by a function-name substring.
public enum ProfileFilter {
    private static func matches(_ name: String, _ query: String) -> Bool { name.lowercased().contains(query) }

    private static func clean(_ query: String) -> String {
        var text = query.lowercased()
        while text.first == " " { text.removeFirst() }
        while text.last == " " { text.removeLast() }
        return text
    }

    public static func top(_ rows: [ProfileTopRow], query: String) -> [ProfileTopRow] {
        let needle = clean(query)
        return needle.isEmpty ? rows : rows.filter { matches($0.name, needle) }
    }

    /// The matching frames with the callers above them and the callees below them, in their original order (parents stay before children).
    public static func nodes(_ nodes: [ProfileNode], query: String) -> [ProfileNode] {
        let needle = clean(query)
        if needle.isEmpty { return nodes }
        var parent: [Int: Int] = [:]
        for node in nodes { parent[node.id] = node.parent }
        var keep = Set<Int>()
        for node in nodes where matches(node.name, needle) {
            var id: Int? = node.id
            while let current = id, !keep.contains(current) { keep.insert(current); id = parent[current] }
        }
        let matched = keep
        // Callees: a node whose parent is kept because of a match above it. Walk in order, so parents are decided first.
        var below = Set<Int>()
        for node in nodes where matched.contains(node.id) && matches(node.name, needle) { below.insert(node.id) }
        var result: [ProfileNode] = []
        for node in nodes {
            if below.contains(node.parent) { below.insert(node.id) }
            if matched.contains(node.id) || below.contains(node.id) { result.append(node) }
        }
        return result
    }
}
