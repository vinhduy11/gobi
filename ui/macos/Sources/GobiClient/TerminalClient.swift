import Foundation
import GobiModel

/// One shell attached to gobid's `pty` channel. Output and the exit arrive on a background thread, so the callbacks hop to
/// the main thread themselves if they touch UI.
public final class TerminalClient: @unchecked Sendable {
    private let session: GobiSession
    private let lock = NSLock()
    private var closed = false
    /// Terminal output bytes, in order.
    public var onOutput: (([UInt8]) -> Void)?
    /// The shell ended (or could not start): its exit code and any text gobid sent with it.
    public var onExit: ((Int, String) -> Void)?

    /// Connects and starts reading. Throws when gobid refuses, for example for a workspace that is not trusted.
    public init(workspaceRoot: String, trusted: Bool) throws {
        session = try Gobid.connect(channel: "pty", workspaceRoot: workspaceRoot, trusted: trusted)
    }

    public func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "gobi-terminal-reader"
        thread.start()
    }

    public func send(_ bytes: [UInt8]) { write(TerminalWire.input(bytes)) }
    public func resize(columns: Int, rows: Int) { write(TerminalWire.resize(columns: columns, rows: rows)) }

    /// Hangs up the terminal; gobid ends the shell.
    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { session.close() }
    }

    private func write(_ payload: [UInt8]) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if !isClosed { try? session.send(payload) }
    }

    private func readLoop() {
        var exited = false
        while let payload = try? session.nextMessage() {
            switch (try? TerminalWire.parse(payload)) ?? .ignored {
            case .output(let bytes): onOutput?(bytes)
            case .exit(let code, let message):
                exited = true
                onExit?(code, message)
            case .ignored: break
            }
            if exited { break }
        }
        if !exited { onExit?(-1, "The connection to gobid ended.") }
        close()
    }
}
