public struct SessionTab: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let character: Int
    public init(path: String, line: Int, character: Int) { self.path = path; self.line = max(0, line); self.character = max(0, character) }
}

/// What a project window reopens with: its tabs (with the caret of each), the active tab and the layout around the editor.
public struct SessionState: Equatable, Sendable {
    public var tabs: [SessionTab] = []
    public var activePath: String?
    public var bottomHidden = false
    public var bottomTab: PanelTab = .problems
    public var sidebarTab = 0
    public var inspectorHidden = false
    public init() {}

    public func encoded() -> String {
        var lines = tabs.map { "tab=\($0.line),\($0.character),\($0.path)" }
        if let activePath { lines.append("active=" + activePath) }
        lines += ["bottomHidden=\(bottomHidden)", "bottomTab=\(bottomTab.rawValue)", "sidebarTab=\(sidebarTab)", "inspectorHidden=\(inspectorHidden)"]
        return lines.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> SessionState {
        var s = SessionState()
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex ..< equals]), value = String(line[line.index(after: equals)...])
            switch key {
            case "tab":
                let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let l = Int(parts[0]), let c = Int(parts[1]), !parts[2].isEmpty { s.tabs.append(SessionTab(path: String(parts[2]), line: l, character: c)) }
            case "active": s.activePath = value
            case "bottomHidden": s.bottomHidden = value == "true"
            case "bottomTab": s.bottomTab = PanelTab(stored: value)
            case "sidebarTab": s.sidebarTab = Int(value) ?? 0
            case "inspectorHidden": s.inspectorHidden = value == "true"
            default: break
            }
        }
        return s
    }

    /// The session without the tabs whose files are gone; the active tab falls back to the first one left.
    public func keeping(_ exists: (String) -> Bool) -> SessionState {
        var s = self
        s.tabs = tabs.filter { exists($0.path) }
        if let active = activePath, !s.tabs.contains(where: { $0.path == active }) { s.activePath = s.tabs.first?.path }
        if s.tabs.isEmpty { s.activePath = nil }
        return s
    }
}

/// When a file was last changed, how big it was and which file it was (inode): enough to notice that something else wrote it.
/// `digest` (see `FileDigest`) is the content of the text read or written; it is looked at only when the metadata is equal.
/// `==` compares the metadata only (an identity of 0 is unknown and matches any).
public struct FileSignature: Equatable, Sendable {
    public let modified: Double
    public let size: Int
    public let identity: UInt64
    public let digest: UInt64?
    public init(modified: Double, size: Int, identity: UInt64 = 0, digest: UInt64? = nil) {
        self.modified = modified; self.size = size; self.identity = identity; self.digest = digest
    }

    public static func == (lhs: FileSignature, rhs: FileSignature) -> Bool {
        lhs.modified == rhs.modified && lhs.size == rhs.size && (lhs.identity == 0 || rhs.identity == 0 || lhs.identity == rhs.identity)
    }
}

/// FNV-1a 64 over the UTF-8 bytes of a text.
public enum FileDigest {
    public static func of(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}

/// Whether a save may write: an automatic one never overwrites a file that changed (or went) on disk, or one whose conflict notice
/// is still unanswered; an explicit Save always writes.
public enum SaveGuard {
    public static func allowed(dirty: Bool, state: DiskState, userInitiated: Bool, conflictPending: Bool) -> Bool {
        if userInitiated { return true }
        return dirty && state == .same && !conflictPending
    }
}

public enum DiskState: Equatable, Sendable { case same, changed, deleted }
public enum DiskAction: Equatable, Sendable { case none, reload, conflict, deleted }

public enum DiskCheck {
    /// `digest` (nil on the cheap poll) hashes the file's content now; it is asked only when the metadata is equal and `known` has one.
    public static func state(known: FileSignature?, current: FileSignature?, digest: (() -> UInt64?)? = nil) -> DiskState {
        switch (known, current) {
        case (nil, nil): return .same
        case (_?, nil): return .deleted
        case (let before, let now):
            guard before == now else { return .changed }
            if let wanted = before?.digest, let digest, let actual = digest(), actual != wanted { return .changed }
            return .same
        }
    }

    /// A file nobody edited here is reloaded quietly; one with unsaved edits asks. Each trouble is reported once (`notified`).
    public static func action(dirty: Bool, state: DiskState, notified: Bool) -> DiskAction {
        switch state {
        case .same: return .none
        case .changed: return dirty ? (notified ? .none : .conflict) : .reload
        case .deleted: return notified ? .none : .deleted
        }
    }
}
