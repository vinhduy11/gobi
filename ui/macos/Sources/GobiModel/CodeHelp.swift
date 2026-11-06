// Values for the code help features (go to definition, completion, hover, format): where something is, and what to offer.
// Plain data; reading them out of gopls' answers is in GobiClient.

public struct SourceLocation: Equatable {
    public var uri: String
    public var start: LSPPosition
    public var end: LSPPosition

    public init(uri: String, start: LSPPosition, end: LSPPosition) {
        self.uri = uri
        self.start = start
        self.end = end
    }
}

public enum CompletionKind: Equatable {
    case method, function, field, variable, type, module, keyword, constant, other

    /// From the protocol's CompletionItemKind number.
    public init(lspKind: Int?) {
        switch lspKind {
        case 2, 4: self = .method
        case 3: self = .function
        case 5, 10: self = .field
        case 6: self = .variable
        case 7, 8, 13, 22, 25: self = .type
        case 9: self = .module
        case 14: self = .keyword
        case 21, 20: self = .constant
        default: self = .other
        }
    }
}

public struct CompletionItem: Equatable {
    public var label: String
    public var kind: CompletionKind
    public var detail: String
    /// The text to put in when the item is chosen and the server gave no edit range.
    public var insertText: String
    /// The edit gopls wants instead: replace a range with `newText` (the range covers what was already typed).
    public var replaces: TextEdit?
    public var sortText: String
    /// True when `insertText` / the edit's text is snippet syntax (insertTextFormat 2) with tab stops.
    public var isSnippet: Bool

    public init(label: String, kind: CompletionKind, detail: String, insertText: String, replaces: TextEdit?, sortText: String, isSnippet: Bool = false) {
        self.isSnippet = isSnippet
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText
        self.replaces = replaces
        self.sortText = sortText
    }
}

/// A fix or refactoring gopls offers, with the edits it makes (by file URI).
public struct CodeAction: Equatable {
    public var title: String
    public var kind: String
    public var edits: [String: [TextEdit]]

    public init(title: String, kind: String, edits: [String: [TextEdit]]) {
        self.title = title
        self.kind = kind
        self.edits = edits
    }
}
