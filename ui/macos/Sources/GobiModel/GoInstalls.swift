/// One Go installation Gobi can see.
public struct GoInstall: Equatable, Sendable {
    public let version: String   // "1.25.9"
    public let source: String    // "System" or "golang.org/dl"
    public let location: String
    public init(version: String, source: String, location: String) { self.version = version; self.source = source; self.location = location }
}

public enum GoInstalls {
    /// Installs from the folders of `~/sdk` (golang.org/dl keeps one `goX.Y.Z` folder per version), newest first.
    public static func fromSDK(folderNames: [String], directory: String) -> [GoInstall] {
        folderNames.compactMap { name -> GoInstall? in
            guard name.hasPrefix("go"), let first = name.dropFirst(2).first, first.isNumber else { return nil }
            return GoInstall(version: String(name.dropFirst(2)), source: "golang.org/dl", location: directory + "/" + name)
        }.sorted { isNewer($0.version, than: $1.version) }
    }

    public static func merge(system: GoInstall?, sdk: [GoInstall]) -> [GoInstall] {
        let others = sdk.filter { $0.version != system?.version }
        return ((system.map { [$0] } ?? []) + others).sorted { isNewer($0.version, than: $1.version) }
    }

    /// Compares dotted numbers one part at a time, so 1.10.0 is newer than 1.9.9.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(x.count, y.count) {
            let left = index < x.count ? x[index] : -1, right = index < y.count ? y[index] : -1
            if left != right { return left > right }
        }
        return false
    }

    public static func projectNote(_ facts: GoModFacts?) -> String {
        guard let facts, !facts.goVersion.isEmpty else { return "No go.mod" }
        var text = "go.mod: go " + facts.goVersion
        if !facts.toolchain.isEmpty { text += " · toolchain " + facts.toolchain }
        return text
    }
}

public struct GoInstallRow: Equatable, Sendable {
    public enum State: Equatable, Sendable { case latest, available, installed }
    public let version: String
    public let state: State
    public init(version: String, state: State) { self.version = version; self.state = state }
}

/// A newer patch release of the newest Go installed here.
public struct GoUpdate: Equatable, Sendable {
    public let installed: String
    public let available: String
    public init(installed: String, available: String) { self.installed = installed; self.available = available }
}

extension GoInstalls {
    /// The Install Version sheet's rows: each release that can be fetched, marked as installed, the latest, or just available.
    public static func installRows(available: [String], installed: [GoInstall]) -> [GoInstallRow] {
        let have = Set(installed.map(\.version))
        return available.enumerated().map { index, version in
            GoInstallRow(version: version, state: have.contains(version) ? .installed : (index == 0 ? .latest : .available))
        }
    }

    /// "go1.26.6 is available" when a newer patch of the newest installed minor exists.
    public static func updateNotice(available: [String], installed: [GoInstall]) -> GoUpdate? {
        guard let newest = installed.map(\.version).sorted(by: { isNewer($0, than: $1) }).first else { return nil }
        let minor = newest.split(separator: ".").prefix(2).joined(separator: ".")
        guard let candidate = available.first(where: { $0 == minor || $0.hasPrefix(minor + ".") }), isNewer(candidate, than: newest) else { return nil }
        return GoUpdate(installed: newest, available: candidate)
    }
}
