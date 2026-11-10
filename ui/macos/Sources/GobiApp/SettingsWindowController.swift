import AppKit
import GobiModel

/// The Settings window (⌘,) from the Settings mocks: General, Editor, Languages, Keymap, Terminal, Git and Advanced. Controls with
/// nothing behind them yet are drawn disabled.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSSegmentedControl(labels: ["General", "Editor", "Languages", "Keymap", "Terminal", "Git", "Advanced", "Appearance"], trackingMode: .selectOne, target: nil, action: nil)
    private let panes: [NSView]
    let general = GeneralSettingsPane(), keymap = KeymapSettingsPane(), terminal = TerminalSettingsPane(), git = GitSettingsPane(), advanced = AdvancedSettingsPane(), appearance = AppearanceSettingsPane()
    let formatOnSave = NSButton(checkboxWithTitle: "Format file", target: nil, action: nil)
    let trimWhitespace = NSButton(checkboxWithTitle: "Trim trailing whitespace", target: nil, action: nil)
    let finalNewline = NSButton(checkboxWithTitle: "Final newline", target: nil, action: nil)
    let loadDotEnv = NSButton(checkboxWithTitle: "Load the project's .env file", target: nil, action: nil)
    let lineNumbers = NSButton(checkboxWithTitle: "Line numbers", target: nil, action: nil)
    let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let lineHeightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tabWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let indentControl = NSSegmentedControl(labels: ["Tabs", "Spaces"], trackingMode: .selectOne, target: nil, action: nil)
    let invisibles = NSButton(checkboxWithTitle: "Invisible characters", target: nil, action: nil)
    let codeLens = NSButton(checkboxWithTitle: "Show code lens", target: nil, action: nil)
    let autoClose = NSButton(checkboxWithTitle: "Close brackets and quotes", target: nil, action: nil)
    let autoIndent = NSButton(checkboxWithTitle: "Keep indentation on a new line", target: nil, action: nil)
    let wrapLines = NSButton(checkboxWithTitle: "Wrap long lines", target: nil, action: nil)
    let rulerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let autoSavePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let goFormat = NSButton(checkboxWithTitle: "Format on save (gofmt)", target: nil, action: nil)

    init() {
        let editor = NSView(), languages = NSView()
        panes = [general, editor, languages, keymap, terminal, git, advanced, appearance]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentStyle = .texturedRounded
        tabs.selectedSegment = 1
        advanced.onCheckSetup = { NSApp.sendAction(#selector(AppDelegate.showSetup(_:)), to: nil, from: nil) }
        tabs.setAccessibilityLabel("Settings sections")

        buildEditor(editor)
        buildLanguages(languages)
        for pane in panes where pane !== editor { pane.isHidden = true }

        let content = NSView()
        for view in [tabs] + panes { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])
        for pane in panes {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14), pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor), pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        window.contentView = content
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The tab showing, in the order General, Editor, Languages, Keymap, Terminal, Git, Advanced, Appearance.
    var selectedPane: Int { panes.firstIndex { !$0.isHidden } ?? 1 }

    func select(pane: Int) {
        guard panes.indices.contains(pane) else { return }
        tabs.selectedSegment = pane
        for (index, view) in panes.enumerated() { view.isHidden = index != pane }
        (panes[pane] as? SettingsPane)?.sync()
    }

    @objc private func tabChanged() { select(pane: tabs.selectedSegment) }

    // MARK: panes

    private func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let stack = NSStackView(views: [label] + controls)
        stack.spacing = 12
        stack.alignment = .firstBaseline
        return stack
    }

    private func disabled<T: NSControl>(_ control: T) -> T { control.isEnabled = false; return control }

    private func popup(_ items: [String], selecting: Int = 0) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: items)
        button.selectItem(at: selecting)
        button.isEnabled = false
        return button
    }

    private func buildEditor(_ view: NSView) {
        for box in [formatOnSave, trimWhitespace, finalNewline] { box.target = self; box.action = #selector(saveOptionsChanged) }
        invisibles.target = self
        invisibles.action = #selector(editorOptionChanged)
        codeLens.target = self
        codeLens.action = #selector(editorOptionChanged)
        for box in [autoClose, autoIndent] { box.target = self; box.action = #selector(editorOptionChanged) }
        wrapLines.target = self
        wrapLines.action = #selector(editorOptionChanged)
        lineNumbers.target = self
        lineNumbers.action = #selector(editorOptionChanged)
        fontPopup.addItems(withTitles: EditorSettings.fontNames)
        sizePopup.addItems(withTitles: EditorSettings.fontSizes.map { "\($0) pt" })
        lineHeightPopup.addItems(withTitles: EditorSettings.lineHeights.map { String($0) })
        tabWidthPopup.addItems(withTitles: EditorSettings.tabWidths.map(String.init))
        indentControl.target = self
        indentControl.action = #selector(editorOptionChanged)
        for popup in [fontPopup, sizePopup, lineHeightPopup, tabWidthPopup] { popup.target = self; popup.action = #selector(editorOptionChanged) }
        rulerPopup.addItems(withTitles: EditorSettings.rulerColumns.map { $0 == 0 ? "None" : String($0) })
        autoSavePopup.addItems(withTitles: ["Off", "After a delay", "When the window loses focus"])
        for popup in [rulerPopup, autoSavePopup] { popup.target = self; popup.action = #selector(editorOptionChanged) }
        loadDotEnv.target = self
        loadDotEnv.action = #selector(dotEnvChanged)
        let hint = NSTextField(labelWithString: "Formatters per language are chosen in Languages.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12)
        let tabsNote = NSTextField(labelWithString: "Go files always use tabs (gofmt)")
        tabsNote.textColor = .secondaryLabelColor
        tabsNote.font = NSFont.systemFont(ofSize: 12)
        let saveBoxes = NSStackView(views: [formatOnSave, trimWhitespace, finalNewline])
        saveBoxes.orientation = .vertical
        saveBoxes.alignment = .leading
        saveBoxes.spacing = 6
        let rows: [NSView] = [
            row("Font", [fontPopup, sizePopup]),
            row("Line height", [lineHeightPopup]),
            row("Indent using", [indentControl, tabsNote]),
            row("Tab width", [tabWidthPopup]),
            row("Show", [lineNumbers, invisibles, codeLens]),
            row("Typing", [autoClose, autoIndent]),
            row("Wrap", [wrapLines]),
            row("Ruler at column", [rulerPopup]),
            row("Auto save", [autoSavePopup]),
            row("On save", [saveBoxes]),
            row("Run", [loadDotEnv]),
            row("", [hint]),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
    }

    private let languageNames = ["Go", "JSON", "Markdown"]
    private let languageList = NSSegmentedControl(labels: ["Go", "JSON", "Markdown"], trackingMode: .selectOne, target: nil, action: nil)
    private var languageDetails: [NSView] = []
    let jsonErrors = NSButton(checkboxWithTitle: "Report syntax errors while typing", target: nil, action: nil)
    let jsonFormat = NSButton(checkboxWithTitle: "Format on save", target: nil, action: nil)
    let previewMode = NSPopUpButton(frame: .zero, pullsDown: false)

    private func detail(_ title: String, _ service: String, _ rows: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let source = NSTextField(labelWithString: service)
        source.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, source] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func buildLanguages(_ view: NSView) {
        goFormat.target = self
        goFormat.action = #selector(goFormatChanged)
        jsonErrors.target = self
        jsonErrors.action = #selector(languageOptionChanged)
        jsonFormat.target = self
        jsonFormat.action = #selector(languageOptionChanged)
        previewMode.addItems(withTitles: MarkdownPreviewMode.allCases.map(\.title))
        previewMode.target = self
        previewMode.action = #selector(languageOptionChanged)
        let note = NSTextField(wrappingLabelWithString: "Strict JSON only: comments and trailing commas are reported as errors.")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 12)
        let outline = NSButton(checkboxWithTitle: "Show keys in the Outline panel", target: nil, action: nil)
        outline.state = .on
        outline.isEnabled = false
        languageDetails = [
            detail("Go", "Language service: gopls", [row("Formatting", [goFormat])]),
            detail("JSON", "Built-in language service", [
                NSTextField(wrappingLabelWithString: "Files: .json. Checked and formatted by Gobi itself; no external tool to install."),
                row("Checking", [jsonErrors]), row("Formatting", [jsonFormat]), row("Indent", [NSTextField(labelWithString: "2 spaces (fixed for now)")]), row("Outline", [outline]), note,
            ]),
            detail("Markdown", "Built-in language service", [
                NSTextField(wrappingLabelWithString: "Files: .md, .markdown. The preview shows Markdown only; raw HTML and script links are removed."),
                row("Open as", [previewMode]), row("Outline", [NSButton(checkboxWithTitle: "Show headings in the Outline panel", target: nil, action: nil)]),
            ]),
        ]
        languageList.target = self
        languageList.action = #selector(languageChosen)
        languageList.selectedSegment = 0
        let detailHolder = NSView()
        for d in languageDetails {
            d.translatesAutoresizingMaskIntoConstraints = false
            detailHolder.addSubview(d)
            NSLayoutConstraint.activate([d.leadingAnchor.constraint(equalTo: detailHolder.leadingAnchor), d.topAnchor.constraint(equalTo: detailHolder.topAnchor), d.trailingAnchor.constraint(lessThanOrEqualTo: detailHolder.trailingAnchor)])
        }
        let columns = NSStackView(views: [languageList, detailHolder])
        columns.orientation = .vertical
        columns.alignment = .centerX
        columns.spacing = 16
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), columns.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            detailHolder.widthAnchor.constraint(equalToConstant: 560), detailHolder.heightAnchor.constraint(equalToConstant: 280),
        ])
        showLanguage(0)
    }

    /// The Languages tab shows one language; for the self-test.
    var shownLanguage: String { languageNames[max(0, languageList.selectedSegment)] }

    func showLanguage(_ index: Int) {
        languageList.selectedSegment = index
        for (i, d) in languageDetails.enumerated() { d.isHidden = i != index }
    }

    @objc private func languageChosen() { showLanguage(languageList.selectedSegment) }

    @objc private func languageOptionChanged() {
        WindowSettings.reportJSONErrors = jsonErrors.state == .on
        WindowSettings.formatJSONOnSave = jsonFormat.state == .on
        WindowSettings.markdownPreviewMode = MarkdownPreviewMode.allCases[max(0, previewMode.indexOfSelectedItem)]
    }

    /// Shows the stored values in the controls.
    func sync() {
        appearance.sync()
        formatOnSave.state = WindowSettings.formatOnSave ? .on : .off
        goFormat.state = formatOnSave.state
        jsonErrors.state = WindowSettings.reportJSONErrors ? .on : .off
        jsonFormat.state = WindowSettings.formatJSONOnSave ? .on : .off
        previewMode.selectItem(at: MarkdownPreviewMode.allCases.firstIndex(of: WindowSettings.markdownPreviewMode) ?? 1)
        trimWhitespace.state = WindowSettings.trimTrailingWhitespace ? .on : .off
        finalNewline.state = WindowSettings.finalNewline ? .on : .off
        loadDotEnv.state = WindowSettings.loadDotEnv ? .on : .off
        let editor = EditorPreferences.current
        lineNumbers.state = editor.showLineNumbers ? .on : .off
        invisibles.state = editor.showInvisibles ? .on : .off
        codeLens.state = editor.showCodeLens ? .on : .off
        autoClose.state = editor.autoClosePairs ? .on : .off
        autoIndent.state = editor.autoIndent ? .on : .off
        wrapLines.state = editor.wrapLines ? .on : .off
        fontPopup.selectItem(withTitle: editor.fontName)
        sizePopup.selectItem(at: EditorSettings.fontSizes.firstIndex(of: editor.fontSize) ?? 2)
        lineHeightPopup.selectItem(at: EditorSettings.lineHeights.firstIndex(of: editor.lineHeight) ?? 2)
        tabWidthPopup.selectItem(at: EditorSettings.tabWidths.firstIndex(of: editor.tabWidth) ?? 1)
        indentControl.selectedSegment = editor.indentWithTabs ? 0 : 1
        rulerPopup.selectItem(at: EditorSettings.rulerColumns.firstIndex(of: editor.rulerColumn) ?? 2)
        autoSavePopup.selectItem(at: [.off, .afterDelay, .onFocusLoss].firstIndex(of: editor.autoSave) ?? 1)
    }

    @objc private func editorOptionChanged() {
        EditorPreferences.update { settings in
            settings.showLineNumbers = lineNumbers.state == .on
            settings.showInvisibles = invisibles.state == .on
            settings.showCodeLens = codeLens.state == .on
            settings.autoClosePairs = autoClose.state == .on
            settings.autoIndent = autoIndent.state == .on
            settings.wrapLines = wrapLines.state == .on
            settings.fontName = fontPopup.titleOfSelectedItem ?? "SF Mono"
            settings.fontSize = EditorSettings.fontSizes[max(0, sizePopup.indexOfSelectedItem)]
            settings.lineHeight = EditorSettings.lineHeights[max(0, lineHeightPopup.indexOfSelectedItem)]
            settings.tabWidth = EditorSettings.tabWidths[max(0, tabWidthPopup.indexOfSelectedItem)]
            settings.indentWithTabs = indentControl.selectedSegment == 0
            settings.rulerColumn = EditorSettings.rulerColumns[max(0, rulerPopup.indexOfSelectedItem)]
            settings.autoSave = [.off, .afterDelay, .onFocusLoss][max(0, autoSavePopup.indexOfSelectedItem)]
        }
    }

    @objc private func dotEnvChanged() { WindowSettings.loadDotEnv = loadDotEnv.state == .on }

    @objc private func saveOptionsChanged() {
        WindowSettings.formatOnSave = formatOnSave.state == .on
        WindowSettings.trimTrailingWhitespace = trimWhitespace.state == .on
        WindowSettings.finalNewline = finalNewline.state == .on
        sync()
    }

    @objc private func goFormatChanged() {
        WindowSettings.formatOnSave = goFormat.state == .on
        sync()
    }
}
