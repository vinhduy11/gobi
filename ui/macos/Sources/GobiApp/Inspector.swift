import AppKit
import GobiModel

/// Settings of the project window kept between runs.
enum WindowSettings {
    private static let formatKey = "gobi.formatOnSave"
    private static let importsKey = "gobi.organizeImportsOnSave"
    private static let trimKey = "gobi.trimTrailingWhitespace"
    private static let newlineKey = "gobi.finalNewline"
    private static let shellKey = "gobi.terminalShell"
    /// The shell new terminals start, an absolute path; empty is the login shell.
    static var terminalShell: String {
        get { defaults.string(forKey: shellKey) ?? "" }
        set { defaults.set(newValue, forKey: shellKey) }
    }

    private static let jsonFormatKey = "gobi.formatJSONOnSave"
    private static let jsonErrorsKey = "gobi.reportJSONErrors"
    private static let previewKey = "gobi.markdownPreviewMode"

    /// Format JSON files (pretty-print through gobid's built-in service) when saving. On by default, as in the mock.
    static var formatJSONOnSave: Bool {
        get { defaults.object(forKey: jsonFormatKey) == nil ? true : defaults.bool(forKey: jsonFormatKey) }
        set { defaults.set(newValue, forKey: jsonFormatKey) }
    }

    /// Show JSON syntax errors as problems while typing.
    static var reportJSONErrors: Bool {
        get { defaults.object(forKey: jsonErrorsKey) == nil ? true : defaults.bool(forKey: jsonErrorsKey) }
        set { defaults.set(newValue, forKey: jsonErrorsKey) }
    }

    /// How a Markdown file opens: Source, Split (source and preview side by side) or Preview.
    static var markdownPreviewMode: MarkdownPreviewMode {
        get { defaults.string(forKey: previewKey).flatMap(MarkdownPreviewMode.init(rawValue:)) ?? .split }
        set { defaults.set(newValue.rawValue, forKey: previewKey) }
    }

    private static let envKey = "gobi.loadDotEnv"
    private static let defaults = UserDefaults.standard

    /// Add the project's .env file to the environment of Run, Test and the other run commands. On by default.
    static var loadDotEnv: Bool {
        get { defaults.object(forKey: envKey) == nil ? true : defaults.bool(forKey: envKey) }
        set { defaults.set(newValue, forKey: envKey) }
    }

    /// Remove spaces and tabs at the ends of lines when saving. On by default, as in the Settings mock.
    static var trimTrailingWhitespace: Bool {
        get { defaults.object(forKey: trimKey) == nil ? true : defaults.bool(forKey: trimKey) }
        set { defaults.set(newValue, forKey: trimKey) }
    }

    /// End the file with exactly one line break when saving.
    static var finalNewline: Bool {
        get { defaults.object(forKey: newlineKey) == nil ? true : defaults.bool(forKey: newlineKey) }
        set { defaults.set(newValue, forKey: newlineKey) }
    }

    /// Format with gofmt (through gopls) when saving a Go file. On by default, as in the mock's status bar.
    static var formatOnSave: Bool {
        get { defaults.object(forKey: formatKey) == nil ? true : defaults.bool(forKey: formatKey) }
        set { defaults.set(newValue, forKey: formatKey) }
    }

    static var organizeImportsOnSave: Bool {
        get { defaults.bool(forKey: importsKey) }
        set { defaults.set(newValue, forKey: importsKey) }
    }
}

/// The list of symbols of the open file, with an icon for each kind and a click to jump to it. Used in the inspector and in the
/// sidebar's Symbols tab.
final class OutlineListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let empty = NSTextField(wrappingLabelWithString: "No symbols")
    private(set) var symbols: [OutlineSymbol.Flat] = []
    var onSelect: ((OutlineSymbol.Flat) -> Void)?

    var titles: [String] { symbols.map(\.displayName) }

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Outline")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), empty.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ symbols: [OutlineSymbol.Flat]) {
        self.symbols = symbols
        empty.isHidden = !symbols.isEmpty
        table.reloadData()
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, table.clickedRow < symbols.count else { return }
        onSelect?(symbols[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { symbols.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let symbol = symbols[row]
        let (letter, colour): (String, NSColor) = {
            switch symbol.kind {
            case .function, .method: return ("ƒ", .systemPurple)
            case .type: return ("T", .systemOrange)
            case .variable: return ("v", .systemBlue)
            case .constant: return ("c", .systemIndigo)
            case .field: return ("f", .systemTeal)
            case .module: return ("m", .systemGreen)
            case .other: return ("·", .secondaryLabelColor)
            }
        }()
        let kind = NSTextField(labelWithString: letter)
        kind.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        kind.textColor = colour
        kind.alignment = .center
        kind.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: symbol.displayName.split(separator: ".").last.map(String.init) ?? symbol.displayName)
        name.font = NSFont.systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [kind, name])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(10 + symbol.depth * 16), bottom: 0, right: 8)
        stack.setAccessibilityLabel(symbol.displayName)
        return stack
    }
}

/// The right-hand inspector of the mock: the open file's outline, the Go module's facts and the settings of this file.
final class InspectorView: NSView {
    let outline = OutlineListView()
    private let moduleName = NSTextField(labelWithString: "—")
    private let goVersion = NSTextField(labelWithString: "—")
    private let workspace = NSTextField(labelWithString: "—")
    private let format = NSButton(checkboxWithTitle: "Format on save (gofmt)", target: nil, action: nil)
    private let imports = NSButton(checkboxWithTitle: "Organize imports on save", target: nil, action: nil)
    private let jsonFormat = NSButton(checkboxWithTitle: "Format on save", target: nil, action: nil)
    private let languageValue = NSTextField(labelWithString: "Go")
    private let detailName = NSTextField(labelWithString: "")
    private let detailValue = NSTextField(labelWithString: "")
    private let previewName = NSTextField(labelWithString: "Preview")
    private let previewValue = NSTextField(labelWithString: "")
    private let goRows = NSStackView()
    private let otherRows = NSStackView()
    private let moduleSection = NSStackView()

    var moduleText: [String] { [moduleName.stringValue, goVersion.stringValue, workspace.stringValue] }

    init() {
        super.init(frame: .zero)
        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        func row(_ title: String, _ value: NSTextField) -> NSStackView {
            let name = NSTextField(labelWithString: title)
            name.textColor = .secondaryLabelColor
            name.font = NSFont.systemFont(ofSize: 12)
            value.font = NSFont.systemFont(ofSize: 12)
            value.lineBreakMode = .byTruncatingHead
            let stack = NSStackView(views: [name, NSView(), value])
            stack.spacing = 8
            return stack
        }
        format.target = self
        format.action = #selector(formatToggled)
        format.state = WindowSettings.formatOnSave ? .on : .off
        imports.target = self
        imports.action = #selector(importsToggled)
        imports.state = WindowSettings.organizeImportsOnSave ? .on : .off
        for box in [format, imports] { box.font = NSFont.systemFont(ofSize: 12) }

        let moduleRows = NSStackView(views: [row("Module", moduleName), row("Go", goVersion), row("Workspace", workspace)])
        moduleRows.orientation = .vertical
        moduleRows.alignment = .leading
        moduleRows.spacing = 4
        goRows.setViews([format, imports], in: .leading)
        goRows.orientation = .vertical
        goRows.alignment = .leading
        goRows.spacing = 4
        jsonFormat.target = self
        jsonFormat.action = #selector(jsonFormatToggled)
        jsonFormat.font = NSFont.systemFont(ofSize: 12)
        let languageRow = row("Language", languageValue)
        let detailRow = NSStackView(views: [detailName, NSView(), detailValue])
        for label in [detailName] { label.textColor = .secondaryLabelColor; label.font = NSFont.systemFont(ofSize: 12) }
        detailValue.font = NSFont.systemFont(ofSize: 12)
        previewName.textColor = .secondaryLabelColor
        previewName.font = NSFont.systemFont(ofSize: 12)
        previewValue.font = NSFont.systemFont(ofSize: 12)
        let previewRow = NSStackView(views: [previewName, NSView(), previewValue])
        otherRows.setViews([languageRow, detailRow, previewRow, jsonFormat], in: .leading)
        otherRows.orientation = .vertical
        otherRows.alignment = .leading
        otherRows.spacing = 4
        otherRows.isHidden = true
        let fileRows = NSStackView(views: [goRows, otherRows])
        fileRows.orientation = .vertical
        fileRows.alignment = .leading
        fileRows.spacing = 4

        let rule1 = NSBox(), rule2 = NSBox()
        rule1.boxType = .separator
        rule2.boxType = .separator
        let stack = NSStackView(views: [header("Outline"), outline, rule1, header("Go module"), moduleRows, rule2, header("This file"), fileRows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            outline.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28), moduleRows.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            rule1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28), rule2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        outline.setContentHuggingPriority(.defaultLow, for: .vertical)
        setAccessibilityLabel("Inspector")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// "This file": the Go switches for a Go file; language, indent and format on save for JSON; language, headings and preview for Markdown.
    func showFile(language: String, text: String, previewMode: MarkdownPreviewMode) {
        goRows.isHidden = language != "go" && language != "plaintext"
        otherRows.isHidden = !goRows.isHidden
        guard language == "json" || language == "markdown" else { return }
        languageValue.stringValue = language == "json" ? "JSON" : "Markdown"
        jsonFormat.isHidden = language != "json"
        previewName.isHidden = language != "markdown"
        previewValue.isHidden = language != "markdown"
        if language == "json" {
            detailName.stringValue = "Indent"
            detailValue.stringValue = FileFacts.jsonIndent(text)
            jsonFormat.state = WindowSettings.formatJSONOnSave ? .on : .off
        } else {
            detailName.stringValue = "Headings"
            detailValue.stringValue = String(FileFacts.headingCount(text))
            previewValue.stringValue = previewMode.inspectorText
        }
    }

    /// What "This file" shows for a JSON or Markdown file, for the self-test.
    var fileSummary: [String] { otherRows.isHidden ? [] : [languageValue.stringValue, detailName.stringValue + " " + detailValue.stringValue] + (previewValue.isHidden ? ["format " + (jsonFormat.state == .on ? "on" : "off")] : ["preview " + previewValue.stringValue]) }

    @objc private func jsonFormatToggled() { WindowSettings.formatJSONOnSave = jsonFormat.state == .on }

    func show(module: GoModFacts?, workspaceName: String?) {
        moduleName.stringValue = module.flatMap { $0.module.isEmpty ? nil : $0.module } ?? "—"
        goVersion.stringValue = module.flatMap { $0.goVersion.isEmpty ? nil : $0.goVersion } ?? "—"
        workspace.stringValue = workspaceName ?? "—"
    }

    var onFormatChanged: (() -> Void)?

    @objc private func formatToggled() { WindowSettings.formatOnSave = format.state == .on; onFormatChanged?() }
    @objc private func importsToggled() { WindowSettings.organizeImportsOnSave = imports.state == .on }
}
