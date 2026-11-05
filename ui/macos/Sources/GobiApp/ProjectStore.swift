import Foundation
import GobiClient
import GobiModel

/// Recent projects and trusted folders, kept in UserDefaults as JSON.
final class ProjectStore {
    static let shared = ProjectStore()
    private let defaults: UserDefaults
    private let recentsKey = "gobi.recentProjects"
    private let trustKey = "gobi.trustedFolders"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var recents: RecentProjects {
        get { load(recentsKey) ?? RecentProjects() }
        set { save(newValue, recentsKey) }
    }

    var trust: TrustList {
        get { load(trustKey) ?? TrustList() }
        set { save(newValue, trustKey) }
    }

    private func load<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

enum ProjectFolder {
    /// Kind of the project in `url`, from the names of the files directly inside it.
    static func kind(of url: URL) -> ProjectKind {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return ProjectKind.detect(entryNames: names)
    }

    /// The folder a chosen URL stands for: a folder itself, or the folder of a go.mod / go.work.
    static func projectRoot(for url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return url }
        return ["go.mod", "go.work"].contains(url.lastPathComponent) ? url.deletingLastPathComponent() : nil
    }
}
