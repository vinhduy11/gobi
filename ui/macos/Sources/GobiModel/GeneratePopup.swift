// Presentation state of Generate: the entries of the popup at the caret and the dialog's form. No templates or code here;
// core renders. The hints only warn early, core still validates every answer.

public enum GeneratePopupEntry: Equatable {
    case item(GenerateItem)
    case heading(String)
    case submenu(String, [GeneratePopupEntry])
    /// gopls' "Fill struct" code action, offered when it returns one for the caret.
    case fillStruct
}

public enum GeneratePopup {
    public static let patternsTitle = "Design Pattern"
    public static let fillStructTitle = "Fill struct"
    static let groups: [(id: String, heading: String)] = [("creational", "CREATIONAL"), ("structural", "STRUCTURAL"), ("behavioral", "BEHAVIORAL")]

    /// Plain items in core's order, then gopls' fill struct, then the patterns under "Design Pattern ▸" by group.
    public static func entries(from items: [GenerateItem], fillStruct: Bool) -> [GeneratePopupEntry] {
        var entries = items.filter { $0.group.isEmpty }.map(GeneratePopupEntry.item)
        if fillStruct { entries.append(.fillStruct) }
        var patterns: [GeneratePopupEntry] = []
        for group in groups {
            let members = items.filter { $0.group == group.id }
            if members.isEmpty { continue }
            patterns.append(.heading(group.heading))
            patterns += members.map(GeneratePopupEntry.item)
        }
        if !patterns.isEmpty { entries.append(.submenu(patternsTitle, patterns)) }
        return entries
    }
}

public enum GenerateTarget: Equatable {
    case current, file
}

/// The dialog of one item: name, ticked fields, one text per parameter and where the code goes.
public struct GenerateForm: Equatable {
    public let item: GenerateItem
    public var name = ""
    public var target = GenerateTarget.current
    public let fieldNames: [String]
    private var texts: [String: String] = [:]
    private var unticked: Set<String> = []

    public init(item: GenerateItem, fieldNames: [String]) {
        self.item = item
        self.fieldNames = fieldNames
        for p in item.params { texts[p.key] = Self.joined(p.defaults, kind: p.kind) }
    }

    /// Names are typed on one line separated by commas; every other list has one entry per line.
    private static func joined(_ values: [String], kind: String) -> String { values.joined(separator: kind == "names" ? ", " : "\n") }

    public func text(of key: String) -> String { texts[key] ?? "" }

    public mutating func set(_ key: String, to text: String) { texts[key] = text }

    public func isTicked(_ field: String) -> Bool { !unticked.contains(field) }

    public mutating func setTicked(_ field: String, _ on: Bool) {
        if on { unticked.remove(field) } else { unticked.insert(field) }
    }

    /// The file a "new file" target creates.
    public var newFileName: String { item.id.split(separator: "-").joined(separator: "_") + ".go" }

    private func values(of param: GenerateParam) -> [String] {
        let text = text(of: param.key)
        guard param.multi else { return text.trimmed.isEmpty ? [] : [text.trimmed] }
        let parts = param.kind == "names" ? text.split(separator: ",", omittingEmptySubsequences: true).map(String.init) : text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return parts.map(\.trimmed).filter { !$0.isEmpty }
    }

    /// A short warning for the entry with this key (a parameter key, "name" or "fields"), or nil when it is fine or blank.
    public func hint(for key: String) -> String? {
        if key == "name" { return item.needsName && !name.trimmed.isEmpty && !Self.validName(name) ? "Not a valid Go name" : nil }
        if key == "fields" && item.needsFields { return !fieldNames.isEmpty && fieldNames.allSatisfy({ !isTicked($0) }) ? "Tick at least one field" : nil }
        guard let param = item.params.first(where: { $0.key == key }) else { return nil }
        let values = values(of: param)
        if values.isEmpty { return nil }
        switch param.kind {
        case "type":
            return Self.validName(values[0]) ? nil : "Not a valid Go name"
        case "names":
            var seen: Set<String> = []
            for value in values {
                if !Self.validName(value) { return "Not a valid Go name" }
                let exported = Self.exported(value)
                if !seen.insert(exported).inserted { return "\(exported) is given twice" }
            }
            return nil
        case "signature":
            let head = values[0].split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            return head.count == 2 && GoSignature.isIdentifier(head[0].trimmed) ? nil : "Write a method signature, like Run(ctx context.Context) error"
        case "fields":
            let bad = values.contains { line in
                guard let space = line.firstIndex(of: " ") else { return true }
                return !GoSignature.isIdentifier(String(line[..<space])) || String(line[space...]).trimmed.isEmpty
            }
            return bad ? "Each line needs a name and a type, like addr string" : nil
        default:
            return nil
        }
    }

    /// Whether every entry is acceptable, so Generate can be pressed.
    public var canGenerate: Bool {
        if item.needsName && (name.trimmed.isEmpty || hint(for: "name") != nil) { return false }
        if hint(for: "fields") != nil { return false }
        return item.params.allSatisfy { hint(for: $0.key) == nil }
    }

    /// Puts the item and the answers into a request (the facts about the caret are already in it).
    public func apply(to request: inout GenerateRequest) {
        request.item = item.id
        request.askedName = name.trimmed
        request.target = target == .file ? "file" : "current"
        request.selected = item.needsFields && fieldNames.contains(where: { !isTicked($0) }) ? fieldNames.filter(isTicked) : []
        request.answers = item.params.compactMap { param in
            let values = values(of: param)
            return values.isEmpty ? nil : GenerateAnswer(key: param.key, values: values)
        }
    }

    private static func validName(_ text: String) -> Bool { GoSignature.isIdentifier(exported(text.trimmed)) }

    private static func exported(_ text: String) -> String {
        let trimmed = text.trimmed
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}

/// SF Symbols of the popup's items (the popup is built from data, so these names are not in `MenuIcons`).
public enum GenerateIcons {
    public static let fallback = "wand.and.stars"
    public static let patterns = "square.grid.2x2"
    public static let fillStruct = "square.and.pencil"

    public static func symbol(forItem id: String, group: String) -> String {
        switch group {
        case "creational": return "plus.square"
        case "structural": return "square.stack.3d.up"
        case "behavioral": return "arrow.triangle.branch"
        default: break
        }
        switch id {
        case "constructor": return "hammer"
        case "options": return "slider.horizontal.3"
        case "accessors": return "arrow.left.arrow.right"
        case "string": return "textformat"
        case "error-type": return "exclamationmark.triangle"
        case "test": return "checkmark.circle"
        case "main": return "play.rectangle"
        case "http-handler": return "network"
        case "mock": return "theatermasks"
        case "implement": return "puzzlepiece"
        default: return fallback
        }
    }
}

extension GenerateContext {
    /// The name in the `package` clause of a source, or nil when there is none.
    public static func packageClause(in source: String) -> String? {
        for line in source.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 2, words[0] == "package" { return String(words[1].prefix { $0 != ";" && $0 != "/" }) }
        }
        return nil
    }
}
