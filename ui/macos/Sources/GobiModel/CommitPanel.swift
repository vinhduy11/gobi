// The model behind the sidebar Commit tool window: the commit button, the changes tree and the stash list. No UI here.

public enum CommitPanelMode: Int, CaseIterable, Sendable {
    case commit, stash, log
    public var title: String {
        switch self {
        case .commit: return "Commit"
        case .stash: return "Stash"
        case .log: return "Log"
        }
    }
}

/// Whether the Commit buttons work, and the note shown under the message field.
public struct CommitButtonState: Equatable, Sendable {
    public let enabled: Bool
    public let warning: String?

    /// A commit needs a message and something to commit; an amend only rewords, so it needs no changes.
    public init(message: String, hasChanges: Bool, amend: Bool, warnLongSubject: Bool) {
        let written = message.contains { !$0.isWhitespace }
        enabled = written && (hasChanges || amend)
        warning = GitSettings.subjectWarning(for: message, enabled: warnLongSubject)
    }

    /// The text to put in an empty message field when Amend is ticked: the last commit's message.
    public static func amendPrefill(message: String, last: GitCommit?) -> String? {
        guard let last, !message.contains(where: { !$0.isWhitespace }) else { return nil }
        return last.subject
    }
}

/// The changed files grouped like IntelliJ's Commit window: "Changes" (versioned) and "Unversioned Files" (untracked).
/// A checked file is a staged one: ticking stages it, unticking unstages it.
public struct ChangesTree: Equatable, Sendable {
    public enum Group: Sendable { case changes, unversioned }
    public enum CheckState: Sendable { case unchecked, mixed, checked }

    /// What to stage and unstage to flip a checkbox.
    public struct Toggle: Equatable, Sendable {
        public let stage: [String]
        public let unstage: [String]
    }

    public struct Section: Equatable, Sendable {
        public let group: Group
        public let files: [GitFile]
        public let collapsed: Bool
        public var title: String { group == .changes ? "Changes" : "Unversioned Files" }
        public var countText: String { files.count == 1 ? "1 file" : "\(files.count) files" }
        public var checkState: CheckState {
            let states = files.map(ChangesTree.checkState(of:))
            return states.allSatisfy { $0 == .checked } ? .checked : (states.allSatisfy { $0 == .unchecked } ? .unchecked : .mixed)
        }
        /// Ticking a group stages what is not staged; when everything is staged it unstages all.
        public func toggle() -> Toggle {
            checkState == .checked ? Toggle(stage: [], unstage: files.map(\.path)) : Toggle(stage: files.filter { ChangesTree.checkState(of: $0) != .checked }.map(\.path), unstage: [])
        }
    }

    public enum Row: Equatable, Sendable {
        case section(Section)
        case file(GitFile)
    }

    public static let emptyText = "No local changes"

    public private(set) var sections: [Section] = []
    private var collapsedGroups: Set<Group> = []

    public init(files: [GitFile]) { self.init(files: files, collapsed: []) }

    private init(files: [GitFile], collapsed: Set<Group>) {
        collapsedGroups = collapsed
        let shown = files.filter { $0.mark != .ignored }
        for (group, members) in [(Group.changes, shown.filter { $0.mark != .untracked }), (.unversioned, shown.filter { $0.mark == .untracked })] where !members.isEmpty {
            sections.append(Section(group: group, files: members, collapsed: collapsed.contains(group)))
        }
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// The section headers, each followed by its files unless collapsed.
    public var rows: [Row] { sections.flatMap { [Row.section($0)] + ($0.collapsed ? [] : $0.files.map(Row.file)) } }

    /// The same collapse state over a new status.
    public func updated(files: [GitFile]) -> ChangesTree { ChangesTree(files: files, collapsed: collapsedGroups) }

    public mutating func toggleCollapsed(_ group: Group) {
        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        refreshSections()
    }
    public mutating func collapseAll() { collapsedGroups = [.changes, .unversioned]; refreshSections() }
    public mutating func expandAll() { collapsedGroups = []; refreshSections() }

    private mutating func refreshSections() {
        sections = sections.map { Section(group: $0.group, files: $0.files, collapsed: collapsedGroups.contains($0.group)) }
    }

    /// Fully staged is checked; staged with more edits since is mixed.
    public static func checkState(of file: GitFile) -> CheckState { file.staged ? (file.unstaged ? .mixed : .checked) : .unchecked }

    /// Flipping a checked file unstages it; an unchecked or mixed one is staged (all of it).
    public static func toggle(file: GitFile) -> Toggle {
        checkState(of: file) == .checked ? Toggle(stage: [], unstage: [file.path]) : Toggle(stage: [file.path], unstage: [])
    }

    /// "cart.go" and "cart" for "cart/cart.go"; a folder entry (trailing slash) keeps its name.
    public static func nameAndFolder(_ path: String) -> (name: String, folder: String) {
        guard !path.hasSuffix("/"), let slash = path.lastIndex(of: "/") else { return (path, "") }
        return (String(path[path.index(after: slash)...]), String(path[..<slash]))
    }
}

/// One entry of the stash list.
public struct StashEntry: Equatable, Sendable {
    public let index: Int
    public let message: String
    public init(index: Int, message: String) { self.index = index; self.message = message }
    public var title: String { "stash@{\(index)}: \(message)" }

    /// Entries are "index, 0x1f, message".
    public static func parse(_ entries: [String]) -> [StashEntry] {
        entries.compactMap { entry in
            let parts = entry.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]) else { return nil }
            return StashEntry(index: index, message: parts[1])
        }
    }
}
