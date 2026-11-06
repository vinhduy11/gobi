import AppKit
import GobiModel

/// Settings > Editor as stored in UserDefaults. A change posts `didChange`; every open editor applies it at once.
enum EditorPreferences {
    static let didChange = Notification.Name("GobiEditorPreferencesDidChange")
    private static let key = "gobi.editorSettings"

    static var current: EditorSettings {
        get { UserDefaults.standard.string(forKey: key).map(EditorSettings.decodeOrDefault) ?? EditorSettings() }
        set {
            UserDefaults.standard.set(newValue.validated().encoded(), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Changes one value and stores the result.
    static func update(_ change: (inout EditorSettings) -> Void) {
        var settings = current
        change(&settings)
        current = settings
    }
}
