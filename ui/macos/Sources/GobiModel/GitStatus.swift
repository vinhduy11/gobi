/// How git sees a path (the digits are the ones gobid sends, core/internal/gitsvc).
public enum GitMark: Int, Equatable, Sendable {
    case modified = 1, added, deleted, renamed, untracked, ignored, conflict

    /// The letter beside a changed file in the Source control block.
    public var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .ignored: return "·"
        case .conflict: return "!"
        }
    }
}

public struct GitFile: Equatable, Sendable {
    /// Relative to the project root; a trailing slash is a whole folder.
    public let path: String
    public let mark: GitMark
    /// Part of the change is in the index / only in the working tree.
    public let staged: Bool
    public let unstaged: Bool
    public init(path: String, mark: GitMark, staged: Bool = false, unstaged: Bool = false) {
        self.path = path; self.mark = mark; self.staged = staged; self.unstaged = unstaged
    }
}

/// A multi-step operation waiting in the repository (the status reply's field 7).
public enum GitOperation: String, Equatable, Sendable {
    case merge, rebase, revert
    case cherryPick = "cherry-pick"
}

public struct GitRemote: Equatable, Sendable {
    public let name: String
    public let url: String
    public init(name: String, url: String) { self.name = name; self.url = url }

    /// Entries are "name, 0x1f, address".
    public static func parse(_ entries: [String]) -> [GitRemote] {
        entries.compactMap { entry in
            let parts = entry.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 ? GitRemote(name: parts[0], url: URLRedaction.redact(parts[1])) : nil
        }
    }
}

public struct GitWorktree: Equatable, Sendable {
    public let path: String
    /// Empty for a detached head.
    public let branch: String
    public let head: String
    public init(path: String, branch: String, head: String) { self.path = path; self.branch = branch; self.head = head }

    public var title: String { branch.isEmpty ? "\(path) (detached \(head.prefix(7)))" : "\(path) (\(branch))" }

    /// Entries are "folder, 0x1f, branch, 0x1f, head".
    public static func parse(_ entries: [String]) -> [GitWorktree] {
        entries.compactMap { entry in
            let parts = entry.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 ? GitWorktree(path: parts[0], branch: parts[1], head: parts[2]) : nil
        }
    }
}

public struct GitStatus: Equatable, Sendable {
    public let branch: String
    public let files: [GitFile]
    /// Commits not pushed yet, and commits upstream that are not here.
    public let ahead: Int
    public let behind: Int
    /// The merge, rebase, revert or cherry-pick waiting for the person, when there is one.
    public let operation: GitOperation?
    public init(branch: String, files: [GitFile], ahead: Int = 0, behind: Int = 0, operation: GitOperation? = nil) {
        self.branch = branch; self.files = files; self.ahead = ahead; self.behind = behind; self.operation = operation
    }

    /// Files git cannot merge by itself.
    public var conflictedFiles: [GitFile] { files.filter { $0.mark == .conflict } }

    /// Files whose change is in the index.
    public var stagedFiles: [GitFile] { files.filter(\.staged) }
    /// Files with a change that is not staged, including new files git does not know yet.
    public var unstagedFiles: [GitFile] { files.filter { $0.unstaged || $0.mark == .untracked } }
    /// Every file with a change to commit or stage (ignored files left out).
    public var changedFiles: [GitFile] { files.filter { $0.mark != .ignored } }

    /// The mark to draw for a file or folder. A file inside a wholly untracked or ignored folder takes the folder's mark; a
    /// folder with a changed file inside is `.modified`; ignored files never colour their folder.
    public func mark(of path: String, isDirectory: Bool) -> GitMark? {
        var best: GitMark?
        for file in files {
            if file.path.hasSuffix("/") {
                let folder = String(file.path.dropLast())
                if path == folder || path.hasPrefix(file.path) { return file.mark }
                if isDirectory, folder.hasPrefix(path + "/"), file.mark != .ignored { best = best ?? .modified }
            } else if file.path == path {
                return file.mark
            } else if isDirectory, file.mark != .ignored, file.path.hasPrefix(path + "/") {
                best = .modified
            }
        }
        return best
    }
}

public struct GitBranch: Equatable, Sendable {
    public let name: String
    public let isCurrent: Bool
    public init(name: String, isCurrent: Bool) { self.name = name; self.isCurrent = isCurrent }
}

public struct GitCommit: Equatable, Sendable {
    public let hash: String
    public let author: String
    public let when: String
    public let subject: String
    public init(hash: String, author: String, when: String, subject: String) { self.hash = hash; self.author = author; self.when = when; self.subject = subject }
    public var shortHash: String { String(hash.prefix(7)) }
}

public struct GitLineChange: Equatable, Sendable {
    public enum Kind: Int, Sendable { case added = 1, modified, deleted }
    public let start: Int
    public let count: Int
    public let kind: Kind
    public init(start: Int, count: Int, kind: Kind) { self.start = start; self.count = count; self.kind = kind }

    /// Lines (1-based) to mark in the gutter: added and modified lines, and lines that follow removed ones.
    public static func marks(for changes: [GitLineChange]) -> (added: Set<Int>, modified: Set<Int>, deletedAfter: Set<Int>) {
        var added = Set<Int>(), modified = Set<Int>(), deleted = Set<Int>()
        for change in changes {
            switch change.kind {
            case .added: for line in change.start ..< change.start + change.count { added.insert(line) }
            case .modified: for line in change.start ..< change.start + change.count { modified.insert(line) }
            case .deleted: deleted.insert(change.start)
            }
        }
        return (added, modified, deleted)
    }
}

/// One line of a unified diff, classified for colouring.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case header, hunk, context, added, removed }
    public let kind: Kind
    public let text: String

    public static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).dropLast(diff.hasSuffix("\n") ? 1 : 0) {
            let text = String(line)
            let kind: Kind
            if text.hasPrefix("@@") { kind = .hunk; inHunk = true }
            else if text.hasPrefix("diff --git") { kind = .header; inHunk = false }
            else if !inHunk { kind = .header }
            else if text.hasPrefix("+") { kind = .added }
            else if text.hasPrefix("-") { kind = .removed }
            else { kind = .context }
            lines.append(DiffLine(kind: kind, text: text))
        }
        return diff.isEmpty ? [] : lines
    }
}

/// A request to gobid's git channel.
public enum GitRequest: Equatable, Sendable {
    case status
    case diff(path: String, staged: Bool)
    case branches
    case checkout(String, create: Bool)
    case stage([String])
    case unstage([String])
    /// amend replaces the last commit instead of adding one.
    case commit(String, amend: Bool = false)
    case log(Int)
    case lines(path: String)
    case discard([String])
    case push
    case pull
    case merge(String)
    case fetch
    case tag(String)
    /// mode is "soft", "mixed" or "hard"; an empty target means HEAD.
    case reset(mode: String, target: String)
    case stash(String)
    case unstash
    case stashList
    /// The n of stash@{n}; 0 is the newest.
    case stashApply(Int)
    case stashPop(Int)
    case stashDrop(Int)
    case abortMerge
    case rebase(String)
    case abortRebase
    case continueRebase
    case skipRebase
    /// Answered with `.text`: the diff of every change since HEAD.
    case patch
    case applyPatch(String)
    case continueRevert
    case abortRevert
    case continueCherryPick
    case abortCherryPick
    case remotes
    case addRemote(name: String, url: String)
    case removeRemote(String)
    case worktrees
    case addWorktree(path: String, branch: String, create: Bool)
    case removeWorktree(String)
}

extension GitRequest {
    /// True when git may rewrite files of the working tree: pending auto saves of open buffers must not run over the result.
    public var changesWorkingTree: Bool {
        switch self {
        case .checkout, .discard, .pull, .merge, .reset, .stash, .unstash, .stashApply, .stashPop, .abortMerge, .rebase, .abortRebase, .continueRebase, .skipRebase,
             .applyPatch, .continueRevert, .abortRevert, .continueCherryPick, .abortCherryPick:
            return true
        default:
            return false
        }
    }
}

public enum GitReply: Equatable, Sendable {
    case status(GitStatus)
    case failure(String)
    case text(String)
    case branches([GitBranch])
    case log([GitCommit])
    case lines([GitLineChange])
    case done
    /// Remotes or worktrees, one entry each (see GitRemote, GitWorktree).
    case list([String])
}

/// The git channel messages (core/internal/daemon/git.go).
public enum GitWire {
    public static func request(_ request: GitRequest) -> [UInt8] {
        var writer = WireWriter()
        switch request {
        case .status: writer.uint(1, 1)
        case .diff(let path, let staged): writer.uint(1, 2); writer.string(5, path); writer.bool(7, staged)
        case .branches: writer.uint(1, 3)
        case .checkout(let name, let create): writer.uint(1, 4); writer.string(5, name); writer.bool(7, create)
        case .stage(let paths): writer.uint(1, 5); for path in paths { writer.string(6, path) }
        case .unstage(let paths): writer.uint(1, 6); for path in paths { writer.string(6, path) }
        case .commit(let message, let amend): writer.uint(1, 7); writer.string(5, message); if amend { writer.bool(7, true) }
        case .log(let count): writer.uint(1, 8); writer.uint(8, UInt64(count))
        case .lines(let path): writer.uint(1, 9); writer.string(5, path)
        case .discard(let paths): writer.uint(1, 10); for path in paths { writer.string(6, path) }
        case .push: writer.uint(1, 11)
        case .pull: writer.uint(1, 12)
        case .merge(let branch): writer.uint(1, 13); writer.string(5, branch)
        case .fetch: writer.uint(1, 14)
        case .tag(let name): writer.uint(1, 15); writer.string(5, name)
        case .reset(let mode, let target): writer.uint(1, 16); writer.string(5, mode); writer.string(9, target)
        case .stash(let message): writer.uint(1, 17); writer.string(5, message)
        case .unstash: writer.uint(1, 18)
        case .abortMerge: writer.uint(1, 19)
        case .rebase(let branch): writer.uint(1, 20); writer.string(5, branch)
        case .abortRebase: writer.uint(1, 21)
        case .continueRebase: writer.uint(1, 22)
        case .skipRebase: writer.uint(1, 23)
        case .patch: writer.uint(1, 24)
        case .applyPatch(let file): writer.uint(1, 25); writer.string(5, file)
        case .continueRevert: writer.uint(1, 26)
        case .abortRevert: writer.uint(1, 27)
        case .continueCherryPick: writer.uint(1, 28)
        case .abortCherryPick: writer.uint(1, 29)
        case .remotes: writer.uint(1, 30)
        case .addRemote(let name, let url): writer.uint(1, 31); writer.string(5, name); writer.string(9, url)
        case .removeRemote(let name): writer.uint(1, 32); writer.string(5, name)
        case .worktrees: writer.uint(1, 33)
        case .addWorktree(let path, let branch, let create): writer.uint(1, 34); writer.string(5, path); writer.bool(7, create); writer.string(9, branch)
        case .removeWorktree(let path): writer.uint(1, 35); writer.string(5, path)
        case .stashList: writer.uint(1, 36)
        case .stashApply(let index): writer.uint(1, 37); writer.uint(8, UInt64(index))
        case .stashPop(let index): writer.uint(1, 38); writer.uint(8, UInt64(index))
        case .stashDrop(let index): writer.uint(1, 39); writer.uint(8, UInt64(index))
        }
        return writer.bytes
    }

    public static func parse(_ payload: [UInt8]) throws -> GitReply {
        var kind: UInt64 = 0
        var branch = "", message = "", body = ""
        var entries: [String] = []
        var ahead = 0, behind = 0
        var operation = ""
        for field in try WireField.parse(payload) {
            switch field.number {
            case 1: kind = field.uint
            case 2: branch = field.string
            case 3: entries.append(field.string)
            case 4: message = field.string
            case 5: ahead = Int(field.uint)
            case 6: behind = Int(field.uint)
            case 7: operation = field.string
            case 8: body = field.string
            default: break
            }
        }
        switch kind {
        case 1:
            let files = entries.compactMap { entry -> GitFile? in
                let characters = Array(entry)
                guard characters.count > 2, let markDigit = characters[0].wholeNumberValue, let mark = GitMark(rawValue: markDigit), let state = characters[1].wholeNumberValue else { return nil }
                return GitFile(path: String(entry.dropFirst(2)), mark: mark, staged: state & 1 != 0, unstaged: state & 2 != 0)
            }
            return .status(GitStatus(branch: branch, files: files, ahead: ahead, behind: behind, operation: GitOperation(rawValue: operation)))
        case 2: return .failure(message)
        case 3: return .text(body)
        case 4: return .branches(entries.compactMap { $0.isEmpty ? nil : GitBranch(name: String($0.dropFirst()), isCurrent: $0.first == "1") })
        case 5:
            return .log(entries.compactMap { entry in
                let parts = entry.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                return parts.count == 4 ? GitCommit(hash: parts[0], author: parts[1], when: parts[2], subject: parts[3]) : nil
            })
        case 6:
            return .lines(entries.compactMap { entry in
                let parts = entry.split(separator: " ").compactMap { Int($0) }
                guard parts.count == 3, let kind = GitLineChange.Kind(rawValue: parts[0]) else { return nil }
                return GitLineChange(start: parts[1], count: parts[2], kind: kind)
            })
        case 7: return .done
        case 8: return .list(entries)
        default: return .failure("unexpected reply from gobid")
        }
    }
}
