import AppKit
import Security
import GobiModel

/// Secrets in the macOS Keychain, one item per project and name. The environments file never holds a secret value.
enum Keychain {
    static func service(for root: String) -> String { "gobi.environment:" + root }

    static func get(_ name: String, root: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: root), kSecAttrAccount as String: name,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, name: String, root: String) -> Bool {
        delete(name, root: root)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: root), kSecAttrAccount as String: name,
                                         kSecValueData as String: Data(value.utf8)]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ name: String, root: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: root), kSecAttrAccount as String: name]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The environment profiles of one project: `.gobi/environments.toml`, which profile is active, and what a run gets from it.
final class ProjectEnvironments {
    let root: URL
    private(set) var file = EnvironmentFile()
    private(set) var loadError: String?
    private var activeKey: String { "gobi.activeEnvironment." + root.path }

    init(root: URL) {
        self.root = root
        reload()
    }

    var fileURL: URL { root.appendingPathComponent(".gobi/environments.toml") }
    /// True when the project has a profile file; without one, runs behave as before (the project's .env is loaded).
    var hasProfiles: Bool { !file.profiles.isEmpty }

    func reload() {
        loadError = nil
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { file = EnvironmentFile(); return }
        do { file = try EnvironmentFile.parse(text) } catch { file = EnvironmentFile(); loadError = "\(fileURL.lastPathComponent): \(error)" }
    }

    func save(_ updated: EnvironmentFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.toml().write(to: fileURL, atomically: true, encoding: .utf8)
        file = updated
    }

    var activeName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: activeKey) ?? ""
            if file.profiles.contains(where: { $0.name == stored }) { return stored }
            return (file.profiles.first(where: \.isDefault) ?? file.profiles.first)?.name ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    var active: EnvProfile? { file.profiles.first { $0.name == activeName } }

    /// What a profile gives a run: its files, variables, Keychain secrets and Go settings resolved, in order of strength.
    func resolved(_ profile: EnvProfile) -> ResolvedEnvironment {
        var files: [String: String] = [:]
        for name in profile.envFiles {
            let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : root.appendingPathComponent(name)
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }   // files stay inside the project
            files[name] = try? String(contentsOf: url, encoding: .utf8)
        }
        var secrets: [String: String] = [:]
        for name in profile.secretNames { secrets[name] = Keychain.get(name, root: root.path) }
        return EnvResolver.resolve(profile, files: files, secrets: secrets.compactMapValues { $0 })
    }

    /// The `KEY=VALUE` entries to send with a run, or nil when the project has no profiles.
    func runEntries() -> [String]? {
        guard let profile = active else { return nil }
        let environment = resolved(profile)
        return environment.keys.compactMap { key in environment.value(of: key).map { key + "=" + $0 } }
    }

    func targets() -> [EnvTarget] { active.map { EnvTargets.find(in: resolved($0)) } ?? [] }

    /// The services a run would touch that are not on this machine, when the active profile asks to be asked first.
    func nonLocalTargetsToConfirm() -> [EnvTarget] {
        guard let profile = active, profile.confirmNonLocal else { return [] }
        return EnvTargets.nonLocal(EnvTargets.find(in: resolved(profile)))
    }
}
