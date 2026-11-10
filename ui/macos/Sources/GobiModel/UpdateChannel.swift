// Which updates Gobi offers. Sparkle shows every item of the default channel to everyone; an item in another channel only to apps that
// asked for it. All releases so far are pre-releases (alpha, beta, rc), so they are the "prerelease" channel; a plain 0.x.y is on the
// default channel and everyone sees it.

public enum UpdateChannel {
    public static let prerelease = "prerelease"

    /// The channel of a release with this version: "prerelease" when it has a pre-release part (`-alpha.8`), nil (the default channel) when not.
    public static func channel(forVersion version: String) -> String? {
        version.contains("-") ? prerelease : nil
    }

    /// The extra channels the app lets Sparkle offer.
    public static func allowed(includePrereleases: Bool) -> Set<String> { includePrereleases ? [prerelease] : [] }
}

extension GeneralSettings {
    /// Whether pre-release updates are offered: what Settings says, and until it says anything, whether the running build is itself a pre-release.
    public func includesPrereleases(currentVersion: String) -> Bool {
        includePrereleases ?? (UpdateChannel.channel(forVersion: currentVersion) != nil)
    }
}
