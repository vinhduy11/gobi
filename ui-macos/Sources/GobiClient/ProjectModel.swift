// What the project window needs to know about a folder, kept free of Foundation so it can be tested on its own.

public enum ProjectKind: String, Codable, Sendable {
    case workspace   // has go.work
    case module      // has go.mod
    case folder      // neither: opens in Restricted Mode with an offer to run `go mod init`

    public static func detect(entryNames: [String]) -> ProjectKind {
        if entryNames.contains("go.work") { return .workspace }
        if entryNames.contains("go.mod") { return .module }
        return .folder
    }
}

public struct FileEntry: Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum FileTree {
    /// Names the explorer never shows: version-control data and macOS metadata.
    private static let hidden: Set<String> = [".git", ".DS_Store"]

    /// Folders first, then names ignoring case; the hidden names are dropped.
    public static func ordered(_ entries: [FileEntry]) -> [FileEntry] {
        entries.filter { !hidden.contains($0.name) }.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let (leftName, rightName) = (left.name.lowercased(), right.name.lowercased())
            return leftName == rightName ? left.name < right.name : leftName < rightName
        }
    }
}

public struct RecentProject: Equatable, Codable, Sendable {
    public var path: String
    public var kind: ProjectKind
}

/// The most recently opened projects, newest first, one entry per path.
public struct RecentProjects: Equatable, Codable, Sendable {
    public private(set) var items: [RecentProject] = []
    public let limit: Int

    public init(limit: Int = 10) { self.limit = limit }

    public mutating func add(path: String, kind: ProjectKind) {
        items.removeAll { $0.path == path }
        items.insert(RecentProject(path: path, kind: kind), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    public mutating func remove(path: String) { items.removeAll { $0.path == path } }
}

/// Folders the user trusted. Trusting a folder trusts everything inside it (this is how "trust projects in the parent
/// folder" works); a sibling that only shares a name prefix is not covered.
public struct TrustList: Equatable, Codable, Sendable {
    public private(set) var paths: [String] = []

    public init() {}

    public mutating func trust(path: String) {
        let clean = Self.withoutTrailingSlash(path)
        if !paths.contains(clean) { paths.append(clean) }
    }

    public func isTrusted(path: String) -> Bool {
        let clean = Self.withoutTrailingSlash(path)
        return paths.contains { clean == $0 || clean.hasPrefix($0 + "/") }
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var clean = path
        while clean.count > 1 && clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }
}
