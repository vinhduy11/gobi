import AppKit
import GobiEditor
import GobiModel

/// Applies Settings > Appearance: the theme's brightness to the app, its colours to the windows, editors and terminals, and follows the
/// OS when "Sync with OS" is on.
enum ThemeController {
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    /// Reads the stored settings and applies them everywhere that is open; windows opened later are styled as they become key.
    static func apply() {
        let settings = AppPreferences.theme
        ThemeColors.systemIsDark = systemIsDark
        ThemeColors.settings = settings
        NSApp.appearance = settings.syncWithOS ? nil : NSAppearance(named: ThemeColors.theme.isDark ? .darkAqua : .aqua)
        NSApp.windows.forEach(style)
        NotificationCenter.default.post(name: EditorPreferences.didChange, object: nil)
    }

    static func style(_ window: NSWindow) { window.backgroundColor = ThemeColors.windowBackground }

    private static var started = false

    /// Applies the stored theme and keeps new windows and an OS appearance change in step with it.
    static func start() {
        apply()
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            if let window = note.object as? NSWindow { style(window) }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if AppPreferences.theme.syncWithOS { apply() } }
        }
    }
}
