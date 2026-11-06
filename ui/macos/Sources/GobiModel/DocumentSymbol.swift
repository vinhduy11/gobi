/// One symbol of a document with everything gopls reports about it: the full range, the range of its name, its type or
/// signature (`detail`), the symbols inside it and the document version it was read at. A flat `SymbolInformation[]` answer
/// gives no children and no detail.
public struct DocumentSymbolInfo: Equatable {
    public var uri: String
    public var name: String
    public var detail: String
    public var kind: OutlineSymbol.Kind
    public var range: (LSPPosition, LSPPosition)
    public var selection: (LSPPosition, LSPPosition)
    public var children: [DocumentSymbolInfo]
    public var version: Int

    public init(uri: String, name: String, detail: String, kind: OutlineSymbol.Kind, range: (LSPPosition, LSPPosition), selection: (LSPPosition, LSPPosition), children: [DocumentSymbolInfo], version: Int) {
        self.uri = uri
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selection = selection
        self.children = children
        self.version = version
    }

    public static func == (a: DocumentSymbolInfo, b: DocumentSymbolInfo) -> Bool {
        a.uri == b.uri && a.name == b.name && a.detail == b.detail && a.kind == b.kind && a.range == b.range && a.selection == b.selection && a.children == b.children && a.version == b.version
    }

    /// The name, kind, line of the name and children, as the outline list wants them.
    public var outline: OutlineSymbol {
        OutlineSymbol(name: name, kind: kind, line: selection.0.line, children: children.map(\.outline))
    }

    /// Whether the position is inside the full range (start included, end excluded).
    public func contains(_ position: LSPPosition) -> Bool {
        !Self.before(position, range.0) && Self.before(position, range.1)
    }

    /// The deepest symbol whose range holds the position, or nil when it falls between declarations.
    public static func innermost(containing position: LSPPosition, in symbols: [DocumentSymbolInfo]) -> DocumentSymbolInfo? {
        guard let outer = symbols.first(where: { $0.contains(position) }) else { return nil }
        return innermost(containing: position, in: outer.children) ?? outer
    }

    private static func before(_ a: LSPPosition, _ b: LSPPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.character < b.character
    }
}
