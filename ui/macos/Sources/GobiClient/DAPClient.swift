import Foundation
import GobiModel

public struct DAPError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

/// A small Debug Adapter Protocol client over gobid's `dap` channel (which runs `dlv dap`): requests with their responses, and
/// events. Callbacks arrive on the reader thread; a caller that touches UI hops to the main thread itself.
public final class DAPClient: @unchecked Sendable {
    private let session: GobiSession
    private let lock = NSLock()
    private var nextSeq = 0
    private var pending = PendingReplies<Result<[String: Any], DAPError>>()

    /// Every event the adapter sends: stopped, continued, terminated, exited, output, initialized, ...
    public var onEvent: ((String, [String: Any]) -> Void)?
    /// Called once when the connection ends.
    public var onDisconnect: (() -> Void)?

    public init(session: GobiSession) { self.session = session }

    /// Connects (gobid starts dlv for the project). Throws when gobid refuses: untrusted project, or dlv not installed.
    public static func connect(workspaceRoot: String) throws -> DAPClient {
        DAPClient(session: try Gobid.connect(channel: "dap", workspaceRoot: workspaceRoot, trusted: true))
    }

    public func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "gobi.dap.reader"
        thread.start()
    }

    public func close() { session.close() }

    // MARK: sending

    public func request(_ command: String, _ arguments: [String: Any]? = nil, completion: @escaping (Result<[String: Any], DAPError>) -> Void) {
        lock.lock()
        nextSeq += 1
        let seq = nextSeq
        pending.add(seq, completion)
        lock.unlock()
        do {
            try session.send(try Self.encodeRequest(seq: seq, command: command, arguments: arguments))
        } catch {
            lock.lock()
            let failed = pending.take(seq)
            lock.unlock()
            failed?(.failure(DAPError(message: "send failed: \(error)")))
        }
    }

    /// Blocks until the response arrives. Not for the main thread.
    public func requestAndWait(_ command: String, _ arguments: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        let slot = Slot()
        request(command, arguments) { outcome in slot.value = outcome; done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { throw DAPError(message: "\(command) timed out") }
        return try slot.value!.get()
    }

    private final class Slot: @unchecked Sendable { var value: Result<[String: Any], DAPError>? }

    public static func encodeRequest(seq: Int, command: String, arguments: [String: Any]?) throws -> [UInt8] {
        var message: [String: Any] = ["seq": seq, "type": "request", "command": command]
        if let arguments { message["arguments"] = arguments }
        return Array(try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]))
    }

    public static func decode(_ bytes: [UInt8]) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any]
    }

    // MARK: reading

    private func readLoop() {
        defer {
            lock.lock()
            let waiting = pending.takeAll()
            lock.unlock()
            for completion in waiting { completion(.failure(DAPError(message: "the debugger connection closed"))) }
            onDisconnect?()
        }
        while let payload = try? session.nextMessage() {
            guard let message = Self.decode(payload) else { continue }
            switch message["type"] as? String {
            case "response":
                guard let seq = message["request_seq"] as? Int else { continue }
                lock.lock()
                let completion = pending.take(seq)
                lock.unlock()
                if message["success"] as? Bool == true {
                    completion?(.success(message["body"] as? [String: Any] ?? [:]))
                } else {
                    completion?(.failure(DAPError(message: message["message"] as? String ?? "request failed")))
                }
            case "event":
                onEvent?(message["event"] as? String ?? "", message["body"] as? [String: Any] ?? [:])
            case "request":
                // A request from the adapter (runInTerminal, startDebugging): not supported.
                let reply: [String: Any] = ["seq": 0, "type": "response", "request_seq": message["seq"] ?? 0, "success": false, "command": message["command"] ?? "", "message": "not supported"]
                if let data = try? JSONSerialization.data(withJSONObject: reply) { try? session.send(Array(data)) }
            default:
                break
            }
        }
    }

    // MARK: reading answers

    public static func frames(from body: [String: Any]) -> [DebugFrame] {
        (body["stackFrames"] as? [[String: Any]] ?? []).map { frame in
            DebugFrame(id: frame["id"] as? Int ?? 0, name: frame["name"] as? String ?? "", path: (frame["source"] as? [String: Any])?["path"] as? String ?? "", line: frame["line"] as? Int ?? 0)
        }
    }

    public static func variables(from body: [String: Any]) -> [DebugVariable] {
        (body["variables"] as? [[String: Any]] ?? []).map { item in
            DebugVariable(name: item["name"] as? String ?? "", type: item["type"] as? String ?? "", value: item["value"] as? String ?? "", reference: item["variablesReference"] as? Int ?? 0)
        }
    }

    public static func threads(from body: [String: Any]) -> [DebugThread] {
        (body["threads"] as? [[String: Any]] ?? []).map { DebugThread(id: $0["id"] as? Int ?? 0, name: $0["name"] as? String ?? "") }
    }

    /// The `breakpoints` array of a setBreakpoints request for one file.
    public static func breakpointEntries(for path: String, in breakpoints: Breakpoints) -> [[String: Any]] {
        breakpoints.lines(in: path).map { line in
            var entry: [String: Any] = ["line": line]
            if let condition = breakpoints.condition(path: path, line: line) { entry["condition"] = condition }
            return entry
        }
    }

    /// The reference of the "Locals" scope (or the only one there is).
    public static func localsReference(from body: [String: Any]) -> Int? {
        let scopes = body["scopes"] as? [[String: Any]] ?? []
        let chosen = scopes.first { ($0["name"] as? String) == "Locals" } ?? (scopes.count == 1 ? scopes[0] : nil)
        return chosen?["variablesReference"] as? Int
    }
}
