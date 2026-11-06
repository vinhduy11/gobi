// What the quick-open panel searches: files, commands and symbols, ranked by how well they match what was typed.

public enum Fuzzy {
    /// Indices of the candidates that match `query`, best first. A name that starts with the query beats one that contains it,
    /// which beats letters found in order (word starts count extra, so "istt" finds internal/server/server_test.go). Ties go to
    /// the shorter name, then to the original order. An empty query keeps everything in the original order.
    public static func rank(_ query: String, in candidates: [String]) -> [Int] {
        let needle = Array(query.lowercased())
        if needle.isEmpty { return Array(candidates.indices) }
        var scored: [(index: Int, score: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            let path = Array(candidate.lowercased())
            let name = Array(path.suffix(while: { $0 != "/" }))
            var score = 0
            if name.starts(with: needle) { score = 3000 }
            else if contains(needle, in: name) { score = 2000 }
            else if contains(needle, in: path) { score = 1500 }
            else if let bonus = subsequenceBonus(needle, in: name) { score = 1000 + bonus }
            else if let bonus = subsequenceBonus(needle, in: path) { score = 500 + bonus }
            else { continue }
            scored.append((index, score - min(name.count, 200)))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.index)
    }

    private static func contains(_ needle: [Character], in text: [Character]) -> Bool {
        guard needle.count <= text.count else { return false }
        for start in 0 ... (text.count - needle.count) where Array(text[start ..< start + needle.count]) == needle { return true }
        return false
    }

    /// nil when the letters do not appear in order; otherwise 10 for each letter that sits at the start of a word.
    private static func subsequenceBonus(_ needle: [Character], in text: [Character]) -> Int? {
        var next = 0, bonus = 0
        for (position, character) in text.enumerated() where next < needle.count && character == needle[next] {
            if position == 0 || "/_.-".contains(text[position - 1]) { bonus += 10 }
            next += 1
        }
        return next == needle.count ? bonus : nil
    }
}

private extension Array {
    func suffix(while predicate: (Element) -> Bool) -> [Element] {
        var result: [Element] = []
        for element in reversed() { if predicate(element) { result.append(element) } else { break } }
        return result.reversed()
    }
}

public struct Command: Equatable {
    public var title: String
    /// "File" or "Edit ▸ Find".
    public var menu: String
    public var shortcut: String
    public var action: String
}

public enum CommandList {
    /// Every menu item that has a feature behind it, as a command.
    public static let all: [Command] = {
        var commands: [Command] = []
        func add(_ menu: String, _ entries: [MenuEntry]) {
            for entry in entries where !entry.isSeparator {
                if let action = entry.action, entry.children.isEmpty { commands.append(Command(title: entry.title, menu: menu, shortcut: entry.shortcut, action: action)) }
                if !entry.children.isEmpty { add(menu + " ▸ " + entry.title, entry.children) }
            }
        }
        for definition in MenuSpec.all { add(definition.title, definition.entries) }
        return commands
    }()

    /// Commands matching what was typed, best first.
    public static func search(_ query: String) -> [Command] {
        Fuzzy.rank(query, in: all.map { $0.title + " " + $0.menu }).map { all[$0] }
    }
}

/// One symbol of a file as gopls reports it (documentSymbol), with the symbols inside it.
public struct OutlineSymbol: Equatable {
    public enum Kind: Equatable {
        case function, method, type, variable, constant, field, module, other

        public init(lspKind: Int) {
            switch lspKind {
            case 12: self = .function
            case 6, 9: self = .method
            case 5, 23, 11, 10: self = .type
            case 13: self = .variable
            case 14: self = .constant
            case 8: self = .field
            case 2, 3, 4: self = .module
            default: self = .other
            }
        }
    }

    public var name: String
    public var kind: Kind
    public var line: Int
    public var children: [OutlineSymbol]

    public init(name: String, kind: Kind, line: Int, children: [OutlineSymbol]) {
        self.name = name
        self.kind = kind
        self.line = line
        self.children = children
    }

    public struct Flat: Equatable {
        public var displayName: String
        public var kind: Kind
        public var line: Int
        public var depth: Int
    }

    /// The symbols as one list: a symbol inside another is named "Outer.Inner" and has depth 1 greater.
    public static func flatten(_ symbols: [OutlineSymbol], parent: String = "", depth: Int = 0) -> [Flat] {
        symbols.flatMap { symbol -> [Flat] in
            let name = parent.isEmpty ? symbol.name : parent + "." + symbol.name
            return [Flat(displayName: name, kind: symbol.kind, line: symbol.line, depth: depth)] + flatten(symbol.children, parent: name, depth: depth + 1)
        }
    }
}

/// A symbol found anywhere in the project (workspace/symbol).
public struct WorkspaceSymbol: Equatable {
    public var name: String
    public var kind: OutlineSymbol.Kind
    public var container: String
    public var location: SourceLocation

    public init(name: String, kind: OutlineSymbol.Kind, container: String, location: SourceLocation) {
        self.name = name
        self.kind = kind
        self.container = container
        self.location = location
    }
}
