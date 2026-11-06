public struct ProfileSampleType: Equatable, Sendable {
    public let type: String
    public let unit: String
    public init(type: String, unit: String) { self.type = type; self.unit = unit }
}

/// One function in the call tree of a profile (core/internal/daemon/control.go, profile/load).
public struct ProfileNode: Equatable, Sendable {
    public let id: Int
    public let parent: Int
    public let name: String
    public let flat: Int
    public let cum: Int
    public let file: String
    public let line: Int
    public init(id: Int, parent: Int, name: String, flat: Int, cum: Int, file: String, line: Int) {
        self.id = id; self.parent = parent; self.name = name; self.flat = flat; self.cum = cum; self.file = file; self.line = line
    }
}

public struct ProfileTopRow: Equatable, Sendable {
    public let name: String
    public let flat: Int
    public let cum: Int
    public init(name: String, flat: Int, cum: Int) { self.name = name; self.flat = flat; self.cum = cum }
}

public struct ProfileData: Equatable, Sendable {
    public var sampleTypes: [ProfileSampleType] = []
    public var index = 0
    public var total = 0
    public var durationNanoseconds = 0
    public var nodes: [ProfileNode] = []
    public var top: [ProfileTopRow] = []

    public var unit: String { sampleTypes.indices.contains(index) ? sampleTypes[index].unit : "" }

    public static func parse(_ fields: [WireField]) throws -> ProfileData {
        var data = ProfileData()
        for field in fields {
            switch field.number {
            case 1:
                var type = "", unit = ""
                for f in try WireField.parse(field.bytes) { if f.number == 1 { type = f.string } else if f.number == 2 { unit = f.string } }
                data.sampleTypes.append(ProfileSampleType(type: type, unit: unit))
            case 2: data.index = Int(field.uint)
            case 3: data.total = Int(field.uint)
            case 4: data.durationNanoseconds = Int(field.uint)
            case 5:
                var id = 0, parent = 0, flat = 0, cum = 0, line = 0
                var name = "", file = ""
                for f in try WireField.parse(field.bytes) {
                    switch f.number {
                    case 1: id = Int(f.uint)
                    case 2: parent = Int(f.uint)
                    case 3: name = f.string
                    case 4: flat = Int(f.uint)
                    case 5: cum = Int(f.uint)
                    case 6: file = f.string
                    case 7: line = Int(f.uint)
                    default: break
                    }
                }
                data.nodes.append(ProfileNode(id: id, parent: parent, name: name, flat: flat, cum: cum, file: file, line: line))
            case 6:
                var name = "", flat = 0, cum = 0
                for f in try WireField.parse(field.bytes) {
                    switch f.number {
                    case 1: name = f.string
                    case 2: flat = Int(f.uint)
                    case 3: cum = Int(f.uint)
                    default: break
                    }
                }
                data.top.append(ProfileTopRow(name: name, flat: flat, cum: cum))
            default: break
            }
        }
        return data
    }
}

/// Numbers as the Profiler mock shows them: "5.46 s", "120 ms", "1.2 MB", "18.2%".
public enum ProfileFormat {
    public static func value(_ value: Int, unit: String) -> String {
        switch unit {
        case "nanoseconds":
            let v = Double(value)
            if v >= 1e9 { return decimal(v / 1e9, 2) + " s" }
            if v >= 1e6 { return trimmed(v / 1e6) + " ms" }
            if v >= 1e3 { return decimal(v / 1e3, 1) + " µs" }
            return String(value) + " ns"
        case "bytes":
            let v = Double(value)
            if v >= 1_048_576 { return decimal(v / 1_048_576, 1) + " MB" }
            if v >= 1024 { return decimal(v / 1024, 1) + " kB" }
            return String(value) + " B"
        default: return String(value)
        }
    }

    public static func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? decimal(Double(part) * 100 / Double(whole), 1) + "%" : "0.0%"
    }

    private static func trimmed(_ x: Double) -> String {
        let whole = decimal(x, 1)
        return whole.hasSuffix(".0") ? String(whole.dropLast(2)) : whole
    }

    private static func decimal(_ x: Double, _ places: Int) -> String {
        var scale = 1
        for _ in 0 ..< places { scale *= 10 }
        let scaled = Int((x * Double(scale)).rounded())
        var fraction = String(scaled % scale)
        while fraction.count < places { fraction = "0" + fraction }
        return String(scaled / scale) + "." + fraction
    }
}

public struct FlameRect: Equatable, Sendable {
    public let id: Int
    public let depth: Int
    /// Left edge and width as fractions of the whole (the root's cost).
    public let x: Double
    public let width: Double
}

public enum FlameLayout {
    /// Icicle layout: the root on top, each node's children side by side underneath it, widths proportional to cumulative cost.
    public static func rects(_ nodes: [ProfileNode]) -> [FlameRect] {
        guard let root = nodes.first, root.cum > 0 else { return [] }
        var placed: [Int: (depth: Int, x: Double)] = [:]
        var used: [Int: Double] = [:]      // how much of a parent's width its children have taken
        var result: [FlameRect] = []
        for node in nodes {
            let width = Double(node.cum) / Double(root.cum)
            var depth = 0, x = 0.0
            if let parent = placed[node.parent] {
                depth = parent.depth + 1
                x = parent.x + (used[node.parent] ?? 0)
                used[node.parent, default: 0] += width
            }
            placed[node.id] = (depth, x)
            result.append(FlameRect(id: node.id, depth: depth, x: x, width: width))
        }
        return result
    }
}

public enum ProfileTree {
    public static func caller(of id: Int, in nodes: [ProfileNode]) -> ProfileNode? {
        guard let node = nodes.first(where: { $0.id == id }), node.parent != 0 else { return nil }
        return nodes.first { $0.id == node.parent }
    }

    public static func callees(of id: Int, in nodes: [ProfileNode]) -> [ProfileNode] { nodes.filter { $0.parent == id } }
}
