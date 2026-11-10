import AppKit
import GobiModel

/// The colours of the chosen theme as NSColors. The app sets `settings` and `systemIsDark` (Settings > Appearance, the OS) and bumps
/// `revision`; the editor compares revisions to know when to repaint.
public enum ThemeColors {
    public static var settings = ThemeSettings() { didSet { revision += 1 } }
    public static var systemIsDark = true { didSet { revision += 1 } }
    public private(set) static var revision = 0

    public static func color(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    public static var theme: AppTheme { settings.effectiveTheme(systemIsDark: systemIsDark) }
    /// What the editor draws with: its own scheme when one is chosen, else the theme.
    public static var editor: ThemePalette { settings.editorPalette(systemIsDark: systemIsDark) }

    public static var accent: NSColor { color(settings.accent.rgb) }
    /// The frame around the panels: the title bar, the status bar and the gaps.
    public static var windowBackground: NSColor { color(theme.palette.window) }
    /// The sidebar, the bottom panel and the inspector: the editor's colour, or a lighter (dark theme) or darker (light theme) one
    /// with "Different tool window background".
    public static var toolWindowBackground: NSColor {
        color(settings.differentToolWindowBackground ? theme.palette.alternateToolWindow : theme.palette.editor)
    }
    /// The terminal and the bottom panel: a shade off the editor in Islands Light and High Contrast, as in JetBrains.
    public static var bottomPanelBackground: NSColor {
        color(settings.differentToolWindowBackground ? theme.palette.alternateBottomPanel : theme.palette.bottomPanel)
    }
    /// Labels of the file tree, tabs and panels, and their quieter second tone.
    public static var uiText: NSColor { color(theme.uiText) }
    public static var uiSecondaryText: NSColor { color(theme.palette.secondaryText) }
    /// Toolbar and panel icons: the theme's text colour (JetBrains draws its icons in it).
    public static var icon: NSColor { color(theme.icon) }
    /// Run, a healthy environment: a green that reads on the theme's brightness.
    public static var positive: NSColor { color(theme.isDark ? RGB(0x5FB865) : RGB(0x59A869)) }
    /// Stop, a failure.
    public static var negative: NSColor { color(theme.isDark ? RGB(0xE06C75) : RGB(0xDB5860)) }
    public static var tabStripBackground: NSColor { color(theme.tabStrip) }
    public static var editorBackground: NSColor { color(editor.editor) }
    public static var editorText: NSColor { color(editor.text) }
    public static var editorSecondaryText: NSColor { color(editor.secondaryText) }
    /// The gutter and the strip beside the text.
    public static var gutterBackground: NSColor { color(editor.window) }
}
