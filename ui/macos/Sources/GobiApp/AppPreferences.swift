import AppKit
import GobiModel

/// The app-wide settings of Settings > General, Terminal, Git and Keymap, kept in UserDefaults. A change posts `didChange` and
/// whoever shows the setting applies it at once.
enum AppPreferences {
    static let didChange = Notification.Name("GobiAppPreferencesDidChange")
    private static let defaults = UserDefaults.standard
    static let keys = ["gobi.generalSettings", "gobi.terminalSettings", "gobi.gitSettings", "gobi.keymapOverrides", "gobi.advancedSettings"]

    static var general: GeneralSettings {
        get { GeneralSettings.decodeOrDefault(defaults.string(forKey: keys[0]) ?? "") }
        set { store(newValue.validated().encoded(), keys[0]) }
    }

    static var terminal: TerminalSettings {
        get { TerminalSettings.decodeOrDefault(defaults.string(forKey: keys[1]) ?? "") }
        set { store(newValue.validated().encoded(), keys[1]) }
    }

    static var git: GitSettings {
        get { GitSettings.decodeOrDefault(defaults.string(forKey: keys[2]) ?? "") }
        set { store(newValue.encoded(), keys[2]) }
    }

    static var keymap: KeymapOverrides {
        get { KeymapOverrides.decode(defaults.string(forKey: keys[3]) ?? "") }
        set { store(newValue.encoded(), keys[3]) }
    }

    /// Once per version: shortcuts customised under the names of an older menu bar move to the current names.
    static func migrateKeymap() {
        let versionKey = "gobi.keymapVersion"
        let version = defaults.integer(forKey: versionKey)
        guard version < KeymapMigration.currentVersion else { return }
        let migrated = KeymapMigration.migrate(keymap, from: version)
        if migrated != keymap { keymap = migrated }
        defaults.set(KeymapMigration.currentVersion, forKey: versionKey)
    }

    static var advanced: AdvancedSettings {
        get { AdvancedSettings.decodeOrDefault(defaults.string(forKey: keys[4]) ?? "") }
        set { store(newValue.encoded(), keys[4]) }
    }

    static func update<Value>(_ path: ReferenceWritableKeyPath<AppPreferences.Type, Value>, _ change: (inout Value) -> Void) {
        var value = AppPreferences.self[keyPath: path]
        change(&value)
        AppPreferences.self[keyPath: path] = value
    }

    private static func store(_ text: String, _ key: String) {
        defaults.set(text, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Settings > Advanced > Reset All Settings: the app-wide and editor settings go back to their defaults. Projects, recent
    /// projects, trusted folders and Keychain secrets are left alone.
    static func resetAll() {
        for key in keys + ["gobi.editorSettings", "gobi.formatOnSave", "gobi.organizeImportsOnSave", "gobi.trimTrailingWhitespace", "gobi.finalNewline",
                           "gobi.appearance", "gobi.loadDotEnv", "gobi.terminalShell"] { defaults.removeObject(forKey: key) }
        WindowSettings.applyAppearance()
        NotificationCenter.default.post(name: didChange, object: nil)
        NotificationCenter.default.post(name: EditorPreferences.didChange, object: nil)
    }
}
