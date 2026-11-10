import AppKit
import GobiClient
import GobiModel
import Sparkle

/// Updates through Sparkle: it reads the appcast in the app's Info.plist (`SUFeedURL`), checks the EdDSA signature of the download
/// against `SUPublicEDKey`, and shows its standard dialogs. Pre-release channels are offered according to Settings > General.
/// Only a build that carries a feed has one (`make-app.sh` writes it); the self-tests and a bare `swift run` binary have none.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!

    /// nil when this build has no update feed.
    static func makeIfConfigured() -> AppUpdater? {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil else { return nil }
        let updater = AppUpdater()
        updater.controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updater, userDriverDelegate: nil)
        return updater
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Settings > General > Updates: whether Sparkle checks by itself (about once a day).
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.allowed(includePrereleases: AppPreferences.general.includesPrereleases(currentVersion: GobiClientVersion.current))
    }
}
