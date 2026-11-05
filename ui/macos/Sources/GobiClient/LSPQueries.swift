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

    public func formatting(uri: String, tabSize: Int, completion: @escaping ([TextEdit]) -> Void) {
        let body: [String: Any] = ["textDocument": ["uri": uri], "options": ["tabSize": tabSize, "insertSpaces": false]]
        _ = request("textDocument/formatting", params: body) { result in
            if case .success(let value) = result { completion(LSPResults.textEdits(value)) } else { completion([]) }
        }
    }

    public func completion(uri: String, at position: LSPPosition, completion: @escaping ([CompletionItem]) -> Void) {
        _ = request("textDocument/completion", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.completions(value)) } else { completion([]) }
        }
    }

    public func hover(uri: String, at position: LSPPosition, completion: @escaping (String?) -> Void) {
        _ = request("textDocument/hover", params: params(uri: uri, position)) { result in
            if case .success(let value) = result { completion(LSPResults.hoverText(value)) } else { completion(nil) }
        }
    }
}
