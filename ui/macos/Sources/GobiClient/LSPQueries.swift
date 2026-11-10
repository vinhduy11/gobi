import Foundation
import GobiModel

/// The questions the editor asks gopls. Each answers on gopls' reader thread, so a caller that touches UI hops to the main thread.
extension LSPClient {
    private func params(uri: String, _ position: LSPPosition) -> [String: Any] {
        ["textDocument": ["uri": uri], "position": ["line": position.line, "character": position.character]]
    }

    public func definition(uri: String, at position: LSPPosition, completion: @escaping ([SourceLocation]) -> Void) {
        _ = request("textDocument/definition", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.locations(value)) } else { completion([]) }
        }
    }

    public func implementation(uri: String, at position: LSPPosition, completion: @escaping ([SourceLocation]) -> Void) {
        _ = request("textDocument/implementation", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.locations(value)) } else { completion([]) }
        }
    }

    /// `insertSpaces` false indents with tabs (Go); JSON uses two spaces.
    public func formatting(uri: String, tabSize: Int, insertSpaces: Bool = false, completion: @escaping ([TextEdit]) -> Void) {
        let body: [String: Any] = ["textDocument": ["uri": uri], "options": ["tabSize": tabSize, "insertSpaces": insertSpaces]]
        _ = request("textDocument/formatting", params: body) { result in
            if case .success(let value) = result { completion(LSPResults.textEdits(value)) } else { completion([]) }
        }
    }

    public func completion(uri: String, at position: LSPPosition, completion: @escaping ([CompletionItem]) -> Void) {
        _ = request("textDocument/completion", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.completions(value)) } else { completion([]) }
        }
    }

    public func signatureHelp(uri: String, at position: LSPPosition, completion: @escaping (SignatureText?) -> Void) {
        _ = request("textDocument/signatureHelp", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(SignatureHelp.parse(value)) } else { completion(nil) }
        }
    }

    /// The semantic tokens of a whole file as gopls' relative-encoded numbers (decode them with `SemanticTokens`).
    public func semanticTokens(uri: String, completion: @escaping ([Int]) -> Void) {
        _ = request("textDocument/semanticTokens/full", params: ["textDocument": ["uri": uri]]) { result in
            if case .success(let value) = result { completion(LSPResults.semanticTokenData(value)) } else { completion([]) }
        }
    }

    public func hover(uri: String, at position: LSPPosition, completion: @escaping (String?) -> Void) {
        _ = request("textDocument/hover", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.hoverText(value)) } else { completion(nil) }
        }
    }

    public func references(uri: String, at position: LSPPosition, completion: @escaping ([SourceLocation]) -> Void) {
        var body = params(uri: uri, position)
        body["context"] = ["includeDeclaration": true]
        _ = request("textDocument/references", params: body) { result in
            if case .success(let value) = result { completion(LSPResults.locations(value)) } else { completion([]) }
        }
    }

    /// Renames the symbol at `position` everywhere; `completion` gets the edits by file, or the server's message on failure.
    public func rename(uri: String, at position: LSPPosition, to name: String, completion: @escaping (Result<[String: [TextEdit]], LSPResponseError>) -> Void) {
        var body = params(uri: uri, position)
        body["newName"] = name
        _ = request("textDocument/rename", params: body) { result in
            completion(result.map { LSPResults.workspaceEdit($0) })
        }
    }

    /// The code actions for a range, limited to the given kinds (for example `source.organizeImports`).
    public func codeActions(uri: String, from start: LSPPosition, to end: LSPPosition, kinds: [String], completion: @escaping ([CodeAction]) -> Void) {
        let range: [String: Any] = ["start": ["line": start.line, "character": start.character], "end": ["line": end.line, "character": end.character]]
        var context: [String: Any] = ["diagnostics": [] as [Any]]
        if !kinds.isEmpty { context["only"] = kinds }
        _ = request("textDocument/codeAction", params: ["textDocument": ["uri": uri], "range": range, "context": context]) { result in
            if case .success(let value) = result { completion(LSPResults.codeActions(value)) } else { completion([]) }
        }
    }

    /// Asks the server for the edit of an action it sent without one. An action that has its edit is returned as it is.
    public func resolve(_ action: CodeAction, completion: @escaping (CodeAction) -> Void) {
        guard action.edits.isEmpty, let json = action.resolveData, let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { completion(action); return }
        _ = request("codeAction/resolve", params: raw) { result in
            if case .success(let value) = result { completion(LSPResults.resolvedCodeAction(value, fallback: action)) } else { completion(CodeAction(title: action.title, kind: action.kind, edits: [:])) }
        }
    }

    public func documentSymbols(uri: String, completion: @escaping ([OutlineSymbol]) -> Void) {
        _ = request("textDocument/documentSymbol", params: ["textDocument": ["uri": uri]]) { result in
            if case .success(let value) = result { completion(LSPResults.documentSymbols(value)) } else { completion([]) }
        }
    }

    /// The symbols of a document with ranges and detail, read at `version`.
    public func documentSymbolInfos(uri: String, version: Int, completion: @escaping ([DocumentSymbolInfo]) -> Void) {
        _ = request("textDocument/documentSymbol", params: ["textDocument": ["uri": uri]]) { result in
            if case .success(let value) = result { completion(LSPResults.documentSymbolInfos(value, uri: uri, version: version)) } else { completion([]) }
        }
    }

    public func workspaceSymbols(query: String, completion: @escaping ([WorkspaceSymbol]) -> Void) {
        _ = request("workspace/symbol", params: ["query": query]) { result in
            if case .success(let value) = result { completion(LSPResults.workspaceSymbols(value)) } else { completion([]) }
        }
    }
}
