import Foundation
import GobiModel

public struct LSPDiagnostic: Equatable, Sendable {
    public var start: LSPPosition
    public var end: LSPPosition
    public var severity: Int
    public var message: String
    public var source: String?

    public init(start: LSPPosition, end: LSPPosition, severity: Int, message: String, source: String?) {
        self.start = start
        self.end = end
        self.severity = severity
        self.message = message
        self.source = source
    }
}

public struct LSPResponseError: Error, CustomStringConvertible, Sendable {
    public var code: Int
    public var message: String
    public var description: String { "LSP error \(code): \(message)" }
}

/// A small LSP client over a GobiSession: request/response matching, notifications, diagnostics.
public final class LSPClient: @unchecked Sendable {
    private let session: GobiSession
    private let lock = NSLock()
    private var nextID = 0
    private var pending = PendingReplies<Result<Any?, LSPResponseError>>()

    /// Called on the reader thread for every textDocument/publishDiagnostics.
    public var onDiagnostics: ((String, [LSPDiagnostic]) -> Void)?
    /// Called on the reader thread for any other notification (e.g. gobi/lspRestarted).
    public var onNotification: ((String, Any?) -> Void)?
    /// Called once when the connection ends.
    public var onDisconnect: (() -> Void)?
    /// textDocumentSync change kind the server asked for: 0 none, 1 full text, 2 incremental.
    public private(set) var syncKind = 1

    public init(session: GobiSession) {
        self.session = session
    }

    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "gobi.lsp.reader"
        thread.stackSize = 1 << 20
        thread.start()
    }

    public func close() { session.close() }

    // MARK: sending

    @discardableResult
    public func request(_ method: String, params: Any?, completion: @escaping (Result<Any?, LSPResponseError>) -> Void) -> Int {
        lock.lock()
        nextID += 1
        let id = nextID
        pending.add(id, completion)
        lock.unlock()
        do {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? NSNull()])
        } catch {
            lock.lock()
            let failed = pending.take(id)
            lock.unlock()
            failed?(.failure(LSPResponseError(code: -32099, message: "send failed: \(error)")))
        }
        return id
    }

    /// Blocks the calling thread until the response arrives. Not for the main thread. On timeout the pending entry is
    /// removed, so a response that comes later is dropped.
    public func requestAndWait(_ method: String, params: Any?, timeout: TimeInterval = 15) throws -> Any? {
        let done = DispatchSemaphore(value: 0)
        let reply = ReplySlot()
        let id = request(method, params: params) { outcome in
            reply.fill(outcome)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            _ = pending.take(id)
            lock.unlock()
            throw LSPResponseError(code: -32098, message: "timed out")
        }
        return try reply.outcome().get()
    }

    public func notify(_ method: String, params: Any?) {
        try? send(["jsonrpc": "2.0", "method": method, "params": params ?? NSNull()])
    }

    private func send(_ message: [String: Any]) throws {
        try session.send(Array(try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])))
    }

    // MARK: protocol helpers

    @discardableResult
    public func initialize(rootPath: String) throws -> [String: Any] {
        let params: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "clientInfo": ["name": "Gobi", "version": GobiClientVersion.current],
            "rootUri": URL(fileURLWithPath: rootPath).absoluteString,
            "capabilities": [
                "textDocument": [
                    "synchronization": ["didSave": false],
                    "publishDiagnostics": ["relatedInformation": false],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                ],
                "general": ["positionEncodings": ["utf-16"]],
            ],
        ]
        let answer = try requestAndWait("initialize", params: params) as? [String: Any] ?? [:]
        if let capabilities = answer["capabilities"] as? [String: Any] {
            switch capabilities["textDocumentSync"] {
            case let kind as Int: syncKind = kind
            case let options as [String: Any]: syncKind = options["change"] as? Int ?? 1
            default: break
            }
        }
        notify("initialized", params: [String: Any]())
        return answer
    }

    public func didOpen(uri: String, languageID: String, version: Int, text: String) {
        notify("textDocument/didOpen", params: ["textDocument": ["uri": uri, "languageId": languageID, "version": version, "text": text]])
    }

    public func didChange(uri: String, version: Int, changes: [[String: Any]]) {
        notify("textDocument/didChange", params: ["textDocument": ["uri": uri, "version": version], "contentChanges": changes])
    }

    public func didClose(uri: String) {
        notify("textDocument/didClose", params: ["textDocument": ["uri": uri]])
    }

    // MARK: receiving

    private func readLoop() {
        defer { failPending(); onDisconnect?() }
        while let payload = try? session.nextMessage() {
            guard let message = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        let method = message["method"] as? String
        switch (method, message["id"]) {
        case (nil, let id?):
            guard let number = id as? Int else { return }
            lock.lock()
            let completion = pending.take(number)
            lock.unlock()
            if let failure = message["error"] as? [String: Any] {
                completion?(.failure(LSPResponseError(code: failure["code"] as? Int ?? -32603, message: failure["message"] as? String ?? "error")))
            } else {
                completion?(.success(message["result"] is NSNull ? nil : message["result"]))
            }
        case (let method?, let id?):
            // A server request (applyEdit, showMessageRequest, ...). The spike answers that it is unsupported.
            try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "client does not support \(method)"]])
        case ("textDocument/publishDiagnostics", nil):
            if let params = message["params"] as? [String: Any], let uri = params["uri"] as? String {
                onDiagnostics?(uri, Self.diagnostics(from: params["diagnostics"]))
            }
        case (let method?, nil):
            onNotification?(method, message["params"])
        default:
            break
        }
    }

    private func failPending() {
        lock.lock()
        let waiting = pending.takeAll()
        lock.unlock()
        for completion in waiting { completion(.failure(LSPResponseError(code: -32099, message: "connection closed"))) }
    }

    static func diagnostics(from raw: Any?) -> [LSPDiagnostic] {
        (raw as? [[String: Any]] ?? []).compactMap { entry in
            guard let range = entry["range"] as? [String: Any],
                  let start = position(range["start"]), let end = position(range["end"]) else { return nil }
            return LSPDiagnostic(start: start, end: end, severity: entry["severity"] as? Int ?? 1,
                                 message: entry["message"] as? String ?? "", source: entry["source"] as? String)
        }
    }

    private static func position(_ raw: Any?) -> LSPPosition? {
        guard let fields = raw as? [String: Any], let line = fields["line"] as? Int, let character = fields["character"] as? Int else { return nil }
        return LSPPosition(line: line, character: character)
    }
}

/// Carries one response from the reader thread to the thread waiting in requestAndWait.
private final class ReplySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Any?, LSPResponseError>?

    func fill(_ outcome: Result<Any?, LSPResponseError>) {
        lock.lock()
        value = outcome
        lock.unlock()
    }

    func outcome() -> Result<Any?, LSPResponseError> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(LSPResponseError(code: -32098, message: "timed out"))
    }
}
