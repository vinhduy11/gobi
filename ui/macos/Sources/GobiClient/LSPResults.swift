import GobiModel

/// Reads the answers gopls sends (already decoded from JSON into dictionaries and arrays) into plain values. Anything that
/// is not the expected shape, including JSON null, gives an empty result rather than an error.
public enum LSPResults {
    private static func position(_ value: Any?) -> LSPPosition? {
        guard let dictionary = value as? [String: Any], let line = dictionary["line"] as? Int, let character = dictionary["character"] as? Int else { return nil }
        return LSPPosition(line: line, character: character)
    }

    private static func range(_ value: Any?) -> (LSPPosition, LSPPosition)? {
        guard let dictionary = value as? [String: Any], let start = position(dictionary["start"]), let end = position(dictionary["end"]) else { return nil }
        return (start, end)
    }

    /// Location, Location[] or LocationLink[]. For a link the selection range (the name) is used.
    public static func locations(_ result: Any?) -> [SourceLocation] {
        let entries: [Any]
        if let list = result as? [Any] { entries = list } else if let single = result as? [String: Any] { entries = [single] } else { return [] }
        return entries.compactMap { entry in
            guard let dictionary = entry as? [String: Any] else { return nil }
            if let uri = dictionary["uri"] as? String, let (start, end) = range(dictionary["range"]) {
                return SourceLocation(uri: uri, start: start, end: end)
            }
            if let uri = dictionary["targetUri"] as? String, let (start, end) = range(dictionary["targetSelectionRange"] ?? dictionary["targetRange"]) {
                return SourceLocation(uri: uri, start: start, end: end)
            }
            return nil
        }
    }

    public static func textEdits(_ result: Any?) -> [TextEdit] {
        guard let list = result as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let dictionary = entry as? [String: Any], let (start, end) = range(dictionary["range"]), let text = dictionary["newText"] as? String else { return nil }
            return TextEdit(start: start, end: end, newText: text)
        }
    }

    /// CompletionItem[] or CompletionList, best match first (by sortText, then label).
    public static func completions(_ result: Any?) -> [CompletionItem] {
        let entries: [Any]
        if let list = result as? [Any] { entries = list } else if let object = result as? [String: Any], let items = object["items"] as? [Any] { entries = items } else { return [] }
        let items = entries.compactMap { entry -> CompletionItem? in
            guard let dictionary = entry as? [String: Any], let label = dictionary["label"] as? String else { return nil }
            var replaces: TextEdit?
            if let edit = dictionary["textEdit"] as? [String: Any], let (start, end) = range(edit["range"] ?? edit["replace"]), let text = edit["newText"] as? String {
                replaces = TextEdit(start: start, end: end, newText: text)
            }
            return CompletionItem(
                label: label, kind: CompletionKind(lspKind: dictionary["kind"] as? Int), detail: dictionary["detail"] as? String ?? "",
                insertText: dictionary["insertText"] as? String ?? label, replaces: replaces, sortText: dictionary["sortText"] as? String ?? label,
                isSnippet: dictionary["insertTextFormat"] as? Int == 2)
        }
        return items.sorted { ($0.sortText, $0.label) < ($1.sortText, $1.label) }
    }

    /// The text of a hover answer: MarkupContent, a string, a MarkedString, or a list of those.
    public static func hoverText(_ result: Any?) -> String? {
        guard let dictionary = result as? [String: Any], let contents = dictionary["contents"] else { return nil }
        func text(_ value: Any) -> String? {
            if let string = value as? String { return string }
            if let markup = value as? [String: Any] { return markup["value"] as? String }
            return nil
        }
        if let list = contents as? [Any] {
            let parts = list.compactMap(text).filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return text(contents).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A WorkspaceEdit as edits by file URI: `changes`, or the text edits of `documentChanges` (file create, rename and
    /// delete operations are not handled and are left out).
    public static func workspaceEdit(_ result: Any?) -> [String: [TextEdit]] {
        guard let edit = result as? [String: Any] else { return [:] }
        var byFile: [String: [TextEdit]] = [:]
        if let changes = edit["changes"] as? [String: Any] {
            for (uri, list) in changes { byFile[uri, default: []] += textEdits(list) }
        }
        if let documents = edit["documentChanges"] as? [Any] {
            for entry in documents {
                guard let change = entry as? [String: Any], let document = change["textDocument"] as? [String: Any], let uri = document["uri"] as? String else { continue }
                byFile[uri, default: []] += textEdits(change["edits"])
            }
        }
        return byFile.filter { !$0.value.isEmpty }
    }

    /// Code actions that come with an edit. Ones that only run a server command are left out.
    public static func codeActions(_ result: Any?) -> [CodeAction] {
        guard let list = result as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let action = entry as? [String: Any], let title = action["title"] as? String else { return nil }
            let edits = workspaceEdit(action["edit"])
            guard !edits.isEmpty else { return nil }
            return CodeAction(title: title, kind: action["kind"] as? String ?? "", edits: edits)
        }
    }

    /// The same answer with ranges, detail and the version it was read at.
    public static func documentSymbolInfos(_ result: Any?, uri: String, version: Int) -> [DocumentSymbolInfo] {
        guard let list = result as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let symbol = entry as? [String: Any], let name = symbol["name"] as? String else { return nil }
            let kind = OutlineSymbol.Kind(lspKind: symbol["kind"] as? Int ?? 0)
            if let full = range(symbol["range"]), let selection = range(symbol["selectionRange"]) {
                return DocumentSymbolInfo(uri: uri, name: name, detail: symbol["detail"] as? String ?? "", kind: kind, range: full, selection: selection,
                                          children: documentSymbolInfos(symbol["children"], uri: uri, version: version), version: version)
            }
            if let location = symbol["location"] as? [String: Any], let place = range(location["range"]) {
                return DocumentSymbolInfo(uri: uri, name: name, detail: "", kind: kind, range: place, selection: place, children: [], version: version)
            }
            return nil
        }
    }

    /// DocumentSymbol[] (a tree, positioned at the symbol's name) or SymbolInformation[] (flat).
    public static func documentSymbols(_ result: Any?) -> [OutlineSymbol] {
        guard let list = result as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let symbol = entry as? [String: Any], let name = symbol["name"] as? String else { return nil }
            let kind = OutlineSymbol.Kind(lspKind: symbol["kind"] as? Int ?? 0)
            if let selection = range(symbol["selectionRange"] ?? symbol["range"]) {
                return OutlineSymbol(name: name, kind: kind, line: selection.0.line, children: documentSymbols(symbol["children"]))
            }
            if let location = symbol["location"] as? [String: Any], let place = range(location["range"]) {
                return OutlineSymbol(name: name, kind: kind, line: place.0.line, children: [])
            }
            return nil
        }
    }

    public static func workspaceSymbols(_ result: Any?) -> [WorkspaceSymbol] {
        guard let list = result as? [Any] else { return [] }
        return list.compactMap { entry in
            guard let symbol = entry as? [String: Any], let name = symbol["name"] as? String, let location = symbol["location"] as? [String: Any],
                  let uri = location["uri"] as? String, let place = range(location["range"]) else { return nil }
            return WorkspaceSymbol(name: name, kind: OutlineSymbol.Kind(lspKind: symbol["kind"] as? Int ?? 0), container: symbol["containerName"] as? String ?? "",
                                   location: SourceLocation(uri: uri, start: place.0, end: place.1))
        }
    }
}
