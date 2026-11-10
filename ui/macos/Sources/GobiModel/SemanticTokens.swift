// gopls' semantic tokens (textDocument/semanticTokens/full) turned into the same per-line tokens the lexer makes. The lexer
// already colours keywords, strings, numbers and comments; these are the names it cannot tell apart: types, functions,
// parameters, properties, constants and packages.

/// The names a server gives its token types and modifiers, in the order the numbers in the data refer to them.
public struct SemanticLegend: Equatable, Sendable {
    public var types: [String]
    public var modifiers: [String]

    public init(types: [String], modifiers: [String]) {
        self.types = types
        self.modifiers = modifiers
    }

    /// From the `capabilities` of an initialize answer; nil when the server offers no semantic tokens.
    public init?(capabilities: [String: Any]) {
        guard let provider = capabilities["semanticTokensProvider"] as? [String: Any], let legend = provider["legend"] as? [String: Any],
              let types = legend["tokenTypes"] as? [String] else { return nil }
        self.init(types: types, modifiers: legend["tokenModifiers"] as? [String] ?? [])
    }
}

public enum SemanticTokens {
    /// The tokens by 0-based line. `data` is the relative encoding: rows of (line delta, start delta, length, type, modifiers),
    /// a start being relative to the previous token on the same line and absolute on a new one. A truncated tail is ignored.
    public static func decode(_ data: [Int], legend: SemanticLegend) -> [Int: [SyntaxToken]] {
        var lines: [Int: [SyntaxToken]] = [:]
        var line = 0, start = 0
        var row = 0
        while row + 5 <= data.count {
            let lineDelta = data[row], startDelta = data[row + 1], length = data[row + 2], type = data[row + 3], modifiers = data[row + 4]
            row += 5
            line += lineDelta
            start = lineDelta == 0 ? start + startDelta : startDelta
            guard legend.types.indices.contains(type), length > 0, let kind = kind(of: legend.types[type], modifiers: names(modifiers, in: legend)) else { continue }
            lines[line, default: []].append(SyntaxToken(start: Int32(start), length: Int32(length), kind: kind))
        }
        return lines
    }

    private static func names(_ bits: Int, in legend: SemanticLegend) -> Set<String> {
        var names: Set<String> = []
        for (index, name) in legend.modifiers.enumerated() where bits >> index & 1 == 1 { names.insert(name) }
        return names
    }

    /// nil for what the lexer colours already and for plain variables, which keep the text colour.
    private static func kind(of type: String, modifiers: Set<String>) -> SyntaxKind? {
        switch type {
        case "namespace": return .namespace
        case "type", "typeParameter", "class", "struct", "interface", "enum": return modifiers.contains("defaultLibrary") ? .builtin : .typeName
        case "parameter": return .parameter
        case "property", "field": return .property
        case "function", "method": return .function
        case "variable": return modifiers.contains("readonly") ? .constant : nil
        default: return nil
        }
    }
}

/// The semantic tokens of an open file, kept in step with the text between gopls' answers: the lines being edited lose theirs
/// (they come back with the next answer) and the lines below an edit that adds or removes lines move with it.
public struct SemanticOverlay: Equatable, Sendable {
    private var lines: [Int: [SyntaxToken]] = [:]

    public init() {}

    public func tokens(line: Int) -> [SyntaxToken] { lines[line] ?? [] }

    public mutating func replace(_ tokens: [Int: [SyntaxToken]]) { lines = tokens }

    /// `oldLineCount` lines starting at `firstLine` became `newLineCount` lines.
    public mutating func edited(firstLine: Int, oldLineCount: Int, newLineCount: Int) {
        let shift = newLineCount - oldLineCount
        var moved: [Int: [SyntaxToken]] = [:]
        for (line, tokens) in lines {
            if line < firstLine { moved[line] = tokens } else if line >= firstLine + oldLineCount { moved[line + shift] = tokens }
        }
        lines = moved
    }
}
