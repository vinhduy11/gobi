import Foundation
import GobiModel

/// One run (go run, test, vet or build) on gobid's `run` channel: connect, start, stream until the exit. The callbacks come
/// from a background thread, so a caller that touches UI hops to the main thread itself.
public final class RunClient: @unchecked Sendable {
    private let session: GobiSession
    private let lock = NSLock()
    private var closed = false
    public var onOutput: (([UInt8], _ stream: Int) -> Void)?
    public var onTest: ((TestEvent) -> Void)?
    /// The run ended: its exit code (128 plus the signal when stopped, 125 when gobid refused the request) and any message.
    public var onExit: ((Int, String) -> Void)?

    /// Connects. Throws when gobid refuses, for example for a workspace that is not trusted.
    public init(workspaceRoot: String, trusted: Bool) throws {
        session = try Gobid.connect(channel: "run", workspaceRoot: workspaceRoot, trusted: trusted)
    }

    /// Sends the request and reads until the exit.
    public func start(command: String, packages: [String], filter: String = "", arguments: [String] = [], envFile: String = "", goRoot: String = "", environment: [String] = []) {
        try? session.send(RunWire.start(command: command, packages: packages, filter: filter, arguments: arguments, envFile: envFile, goRoot: goRoot, environment: environment))
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "gobi-run-reader"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if !isClosed { try? session.send(RunWire.stop()) }
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { session.close() }
    }

    private func readLoop() {
        var exited = false
        while !exited, let payload = try? session.nextMessage() {
            switch (try? RunWire.parse(payload)) ?? .ignored {
            case .output(let bytes, let stream): onOutput?(bytes, stream)
            case .test(let event): onTest?(event)
            case .exit(let code, let message):
                exited = true
                onExit?(code, message)
            case .ignored: break
            }
        }
        if !exited { onExit?(-1, "The connection to gobid ended.") }
        close()
    }
}
