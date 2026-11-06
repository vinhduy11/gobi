import Foundation
import GobiModel

public enum GitClientError: Error, CustomStringConvertible {
    case closed, unexpected
    case git(String)
    public var description: String {
        switch self {
        case .closed: return "the connection to gobid ended"
        case .unexpected: return "unexpected reply from gobid"
        case .git(let message): return URLRedaction.redact(message)
        }
    }
}

/// gobid's `git` channel: one question, "what does git say about this project", answered per call. `status()` blocks, so call it
/// off the main thread.
public final class GitClient: @unchecked Sendable {
    private let session: GobiSession
    private let lock = NSLock()

    /// Connects. Throws when gobid refuses, for example for a workspace that is not trusted.
    /// `gitPath`: an absolute path to the git program to use; empty uses the git on PATH.
    public init(workspaceRoot: String, trusted: Bool, gitPath: String = "") throws {
        session = try Gobid.connect(channel: "git", workspaceRoot: workspaceRoot, tool: gitPath, trusted: trusted)
    }

    /// Sends one request and waits for its reply (replies come in order). Blocks, so call it off the main thread.
    public func send(_ request: GitRequest) throws -> GitReply {
        lock.lock()
        defer { lock.unlock() }
        try session.send(GitWire.request(request))
        guard let reply = try session.nextMessage() else { throw GitClientError.closed }
        let parsed = try GitWire.parse(reply)
        if case .failure(let message) = parsed { throw GitClientError.git(message) }
        return parsed
    }

    public func status() throws -> GitStatus {
        guard case .status(let status) = try send(.status) else { throw GitClientError.unexpected }
        return status
    }

    public func diff(path: String, staged: Bool) throws -> String {
        guard case .text(let text) = try send(.diff(path: path, staged: staged)) else { throw GitClientError.unexpected }
        return text
    }

    public func branches() throws -> [GitBranch] {
        guard case .branches(let list) = try send(.branches) else { throw GitClientError.unexpected }
        return list
    }

    /// Every change since HEAD as a patch.
    public func patch() throws -> String {
        guard case .text(let text) = try send(.patch) else { throw GitClientError.unexpected }
        return text
    }

    public func remotes() throws -> [GitRemote] {
        guard case .list(let entries) = try send(.remotes) else { throw GitClientError.unexpected }
        return GitRemote.parse(entries)
    }

    public func worktrees() throws -> [GitWorktree] {
        guard case .list(let entries) = try send(.worktrees) else { throw GitClientError.unexpected }
        return GitWorktree.parse(entries)
    }

    public func stashes() throws -> [StashEntry] {
        guard case .list(let entries) = try send(.stashList) else { throw GitClientError.unexpected }
        return StashEntry.parse(entries)
    }

    public func log(_ count: Int = 50) throws -> [GitCommit] {
        guard case .log(let list) = try send(.log(count)) else { throw GitClientError.unexpected }
        return list
    }

    public func changedLines(path: String) throws -> [GitLineChange] {
        guard case .lines(let list) = try send(.lines(path: path)) else { throw GitClientError.unexpected }
        return list
    }

    /// Stage, unstage, commit and checkout answer "done" or throw git's own message.
    public func perform(_ request: GitRequest) throws {
        guard case .done = try send(request) else { throw GitClientError.unexpected }
    }

    public func close() { session.close() }
}
