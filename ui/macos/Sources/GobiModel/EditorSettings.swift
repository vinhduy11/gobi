/// The Settings > Editor values (docs/implement/editor-settings.md). Pure: the app stores `encoded()` text and applies the
/// values to every open editor.
public struct EditorSettings: Equatable, Sendable {
    public enum AutoSave: String, Sendable { case off, afterDelay, onFocusLoss }

    public static let fontSizes = [11, 12, 13, 14, 16, 18]
    public static let lineHeights: [Double] = [1.0, 1.2, 1.4, 1.6]
    public static let tabWidths = [2, 4, 8]
    public static let rulerColumns = [0, 80, 100, 120]   // 0 is no ruler
    public static let fontNames = ["SF Mono", "Menlo", "Monaco", "Courier New"]

    public var fontName = "SF Mono"
    public var fontSize = 13
    public var lineHeight = 1.4
    public var indentWithTabs = true
    public var tabWidth = 4
    public var showLineNumbers = true
    public var showInvisibles = false
    public var showCodeLens = true
    public var wrapLines = false
    public var rulerColumn = 100
    public var autoSave = AutoSave.afterDelay

    public init() {}

    /// Every value moved to the nearest one the lists allow.
    public func validated() -> EditorSettings {
        var s = self
        s.fontSize = Self.nearest(fontSize, in: Self.fontSizes)
        s.tabWidth = Self.nearest(tabWidth, in: Self.tabWidths)
        s.rulerColumn = rulerColumn == 0 ? 0 : Self.nearest(rulerColumn, in: Self.rulerColumns.filter { $0 > 0 })
        s.lineHeight = Self.lineHeights.min { abs($0 - lineHeight) < abs($1 - lineHeight) } ?? 1.4
        if !Self.fontNames.contains(fontName) { s.fontName = "SF Mono" }
        return s
    }

    private static func nearest(_ value: Int, in list: [Int]) -> Int {
        list.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// The settings that change how text is laid out; a change here means rewriting the text's attributes.
    public struct Look: Equatable, Sendable { public let fontName: String; public let fontSize: Int; public let lineHeight: Double; public let tabWidth: Int }
    public var look: Look { Look(fontName: fontName, fontSize: fontSize, lineHeight: lineHeight, tabWidth: tabWidth) }

    /// What one press of Tab or one indent level inserts. Go files always use tabs (gofmt).
    public func indentUnit(forLanguage language: String) -> String {
        if language == "go" || indentWithTabs { return "\t" }
        return String(repeating: " ", count: tabWidth)
    }

    // MARK: storing

    public func encoded() -> String {
        [
            "fontName=\(fontName)", "fontSize=\(fontSize)", "lineHeight=\(lineHeight)", "indentWithTabs=\(indentWithTabs)",
            "tabWidth=\(tabWidth)", "showLineNumbers=\(showLineNumbers)", "showInvisibles=\(showInvisibles)", "showCodeLens=\(showCodeLens)","wrapLines=\(wrapLines)",
            "rulerColumn=\(rulerColumn)", "autoSave=\(autoSave.rawValue)",
        ].joined(separator: "\n")
    }

    /// Nil when the text holds no known setting. Unknown or unreadable lines are skipped; the rest is validated.
    public static func decode(_ text: String) -> EditorSettings? {
        var s = EditorSettings()
        var found = false
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "fontName": s.fontName = value
            case "fontSize": if let v = Int(value) { s.fontSize = v } else { continue }
            case "lineHeight": if let v = Double(value) { s.lineHeight = v } else { continue }
            case "indentWithTabs": s.indentWithTabs = value == "true"
            case "tabWidth": if let v = Int(value) { s.tabWidth = v } else { continue }
            case "showLineNumbers": s.showLineNumbers = value == "true"
            case "showInvisibles": s.showInvisibles = value == "true"
            case "showCodeLens": s.showCodeLens = value == "true"
            case "wrapLines": s.wrapLines = value == "true"
            case "rulerColumn": if let v = Int(value) { s.rulerColumn = v } else { continue }
            case "autoSave": if let v = AutoSave(rawValue: value) { s.autoSave = v } else { continue }
            default: continue
            }
            found = true
        }
        return found ? s.validated() : nil
    }

    public static func decodeOrDefault(_ text: String) -> EditorSettings { decode(text) ?? EditorSettings() }
}
