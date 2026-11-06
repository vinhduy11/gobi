public enum ToolchainMode: String, Sendable { case auto, pinned, installedOnly }

/// A project's Go choice: follow go.mod, pin one version, or use only what is installed.
public struct ToolchainSelection: Equatable, Sendable {
    public var mode: ToolchainMode
    public var pinnedVersion: String
    public init(mode: ToolchainMode = .auto, pinnedVersion: String = "") { self.mode = mode; self.pinnedVersion = pinnedVersion }

    public func encoded() -> String { "\(mode.rawValue)|\(pinnedVersion)" }

    public static func decode(_ text: String) -> ToolchainSelection {
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let mode = ToolchainMode(rawValue: parts[0]) else { return ToolchainSelection() }
        return ToolchainSelection(mode: mode, pinnedVersion: parts[1])
    }
}

public struct ToolchainMenuItem: Equatable, Sendable {
    public let title: String
    public let isChecked: Bool
    /// The version a click pins; nil for the Auto entry.
    public let version: String?
}

/// Which Go a project uses (docs/implement/toolchains.md).
public enum ToolchainChoice {
    public enum Resolution: Equatable, Sendable {
        /// No override: the `go` on PATH.
        case system
        case install(GoInstall)
        /// Nothing installed satisfies this version.
        case missing(wanted: String)
    }

    public static func resolve(_ selection: ToolchainSelection, goMod: GoModFacts?, installs: [GoInstall]) -> Resolution {
        if selection.mode == .pinned {
            return installs.first { $0.version == selection.pinnedVersion }.map(Resolution.install) ?? .missing(wanted: selection.pinnedVersion)
        }
        // Before the installed versions are known, or without a go.mod line, the go on PATH decides (as before this feature).
        guard let goMod, !goMod.goVersion.isEmpty, !installs.isEmpty else { return .system }
        let toolchain = goMod.toolchain.hasPrefix("go") ? String(goMod.toolchain.dropFirst(2)) : goMod.toolchain
        if !toolchain.isEmpty, let exact = installs.first(where: { $0.version == toolchain }) { return .install(exact) }
        // "go 1.25" is a minimum: take the system Go when it meets it, else the newest install that does.
        let satisfying = installs.filter { !GoInstalls.isNewer(goMod.goVersion, than: $0.version) }
        if let system = satisfying.first(where: { $0.source == "System" }) { return .install(system) }
        if let newest = satisfying.sorted(by: { GoInstalls.isNewer($0.version, than: $1.version) }).first { return .install(newest) }
        return .missing(wanted: toolchain.isEmpty ? goMod.goVersion : toolchain)
    }

    /// The folder to send with a run (`~` expanded), "" for the PATH go, nil when the version is missing.
    public static func goRoot(_ resolution: Resolution, home: String) -> String? {
        switch resolution {
        case .system: return ""
        case .missing: return nil
        case .install(let install): return install.location.hasPrefix("~") ? home + install.location.dropFirst() : install.location
        }
    }

    public static func menuItems(selection: ToolchainSelection, goMod: GoModFacts?, installs: [GoInstall]) -> [ToolchainMenuItem] {
        let auto = goMod.map { $0.goVersion.isEmpty ? "Auto" : "Auto (go.mod: go \($0.goVersion))" } ?? "Auto"
        var items = [ToolchainMenuItem(title: auto, isChecked: selection.mode != .pinned, version: nil)]
        for install in installs {
            items.append(ToolchainMenuItem(title: "go" + install.version, isChecked: selection.mode == .pinned && selection.pinnedVersion == install.version, version: install.version))
        }
        return items
    }
}
