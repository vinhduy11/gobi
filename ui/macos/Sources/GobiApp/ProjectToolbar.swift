import AppKit
import GobiModel

/// A flat icon or text button for the toolbar, with a soft highlight under the pointer (IntelliJ style, no capsule).
final class FlatToolbarButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(symbol: String?, title: String = "", label: String, tint: NSColor? = nil, chevron: Bool = false, action: Selector?, target: AnyObject?) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        contentTintColor = tint
        font = NSFont.systemFont(ofSize: 13)
        self.title = title + (chevron ? "  ⌄" : "")
        toolTip = label
        setAccessibilityLabel(label)
        self.action = action
        self.target = target
        isEnabled = action != nil
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant: 30).isActive = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        alphaValue = isEnabled ? 1 : 0.45
        super.draw(dirtyRect)
    }
}

/// The window toolbar of the Main mock, IntelliJ style: sidebar toggle, project and branch on the left; the run configuration
/// with Run, Debug and Profile, then environment and Go version in the middle; search and inspector toggle on the right.
/// Profile is drawn dimmed until those features exist.
final class ProjectToolbar: NSObject, NSToolbarDelegate {
    private enum Item {
        static let sidebar = NSToolbarItem.Identifier("sidebar"), project = NSToolbarItem.Identifier("project"), branch = NSToolbarItem.Identifier("branch")
        static let target = NSToolbarItem.Identifier("target"), run = NSToolbarItem.Identifier("run"), debug = NSToolbarItem.Identifier("debug")
        static let more = NSToolbarItem.Identifier("more"), environment = NSToolbarItem.Identifier("environment"), toolchain = NSToolbarItem.Identifier("toolchain")
        static let search = NSToolbarItem.Identifier("search"), inspector = NSToolbarItem.Identifier("inspector")
    }

    private let toolbar = NSToolbar(identifier: "GobiProject2")
    private var buttons: [NSToolbarItem.Identifier: FlatToolbarButton] = [:]
    private var statusSummary = ""
    var toolchainMenu: () -> NSMenu? = { nil }
    var projectMenu: () -> NSMenu? = { nil }
    var branchMenu: () -> NSMenu? = { nil }
    var environmentMenu: () -> NSMenu? = { nil }
    var onToggleSidebar: () -> Void = {}
    var onToggleInspector: () -> Void = {}
    var onRun: () -> Void = {}
    var onDebug: () -> Void = {}
    var moreMenu: () -> NSMenu? = { nil }
    var onStop: () -> Void = {}
    var onSearch: () -> Void = {}
    private var running = false

    var targetText: String { buttons[Item.target]?.title.replacingOccurrences(of: "  ⌄", with: "") ?? "" }
    var statusText: String { statusSummary }
    var toolchainText: String { buttons[Item.toolchain]?.title.replacingOccurrences(of: "  ⌄", with: "") ?? "" }
    var runTitle: String { running ? "Stop" : "Run" }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func install(in window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
    }

    func set(project: String, branch: String?, target: String, toolchain: String, status: String) {
        statusSummary = status
        buttons[Item.project]?.title = project + "  ⌄"
        buttons[Item.project]?.toolTip = status
        buttons[Item.branch]?.title = (branch ?? "no git") + "  ⌄"
        buttons[Item.target]?.title = target + "  ⌄"
        buttons[Item.toolchain]?.title = toolchain + "  ⌄"
        buttons[Item.toolchain]?.toolTip = "Go toolchain used by Run, Test and gopls"
    }

    /// The Run button turns into Stop while something runs.
    func set(running: Bool) {
        self.running = running
        guard let run = buttons[Item.run] else { return }
        run.image = NSImage(systemSymbolName: running ? "stop.fill" : "play.fill", accessibilityDescription: runTitle)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        run.contentTintColor = running ? .systemRed : .systemGreen
        run.toolTip = runTitle
        run.setAccessibilityLabel(runTitle)
    }

    // MARK: delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.sidebar, Item.project, Item.branch, Item.environment, Item.toolchain, .flexibleSpace, Item.target, Item.run, Item.debug, Item.more, Item.search, Item.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let button: FlatToolbarButton
        switch id {
        case Item.sidebar: button = FlatToolbarButton(symbol: "sidebar.left", label: "Toggle sidebar", action: #selector(sidebar), target: self)
        case Item.project: button = FlatToolbarButton(symbol: nil, title: "Project", label: "Project", action: #selector(projectPressed), target: self)
        case Item.branch: button = FlatToolbarButton(symbol: "arrow.triangle.branch", title: "main", label: "Branch", tint: .secondaryLabelColor, action: #selector(branchPressed), target: self)
        case Item.target: button = FlatToolbarButton(symbol: "folder", title: "go run .", label: "Run configuration", action: nil, target: nil)
        case Item.run: button = FlatToolbarButton(symbol: "play.fill", label: "Run", tint: .systemGreen, action: #selector(runPressed), target: self)
        case Item.debug: button = FlatToolbarButton(symbol: "ladybug", label: "Debug", action: #selector(debugPressed), target: self)
        case Item.more: button = FlatToolbarButton(symbol: "ellipsis", label: "More run actions", action: #selector(morePressed), target: self)
        case Item.environment: button = FlatToolbarButton(symbol: "circle.fill", title: "local", label: "Environment", tint: .systemGreen, action: #selector(environmentPressed), target: self)
        case Item.toolchain: button = FlatToolbarButton(symbol: nil, title: "Go", label: "Go toolchain", action: #selector(toolchainPressed), target: self)
        case Item.search: button = FlatToolbarButton(symbol: "magnifyingglass", label: "Search and commands (⇧⌘P)", action: #selector(search), target: self)
        case Item.inspector: button = FlatToolbarButton(symbol: "sidebar.right", label: "Toggle inspector", action: #selector(inspector), target: self)
        default: return nil
        }
        if id == Item.project { button.font = NSFont.systemFont(ofSize: 13, weight: .semibold) }
        if id == Item.branch || id == Item.environment || id == Item.toolchain { button.contentTintColor = id == Item.environment ? .systemGreen : .secondaryLabelColor }
        buttons[id] = button
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.isBordered = false
        if #available(macOS 26.0, *) { item.style = .plain }
        return item
    }

    @objc private func toolchainPressed() { popUp(toolchainMenu(), from: buttons[Item.toolchain]) }
    @objc private func environmentPressed() { popUp(environmentMenu(), from: buttons[Item.environment]) }

    func set(environment: String, remote: Bool) {
        buttons[Item.environment]?.title = environment + "  ⌄"
        buttons[Item.environment]?.contentTintColor = remote ? .systemOrange : .systemGreen
        buttons[Item.environment]?.toolTip = "Environment: " + environment
    }

    @objc private func branchPressed() { popUp(branchMenu(), from: buttons[Item.branch]) }
    @objc private func projectPressed() { popUp(projectMenu(), from: buttons[Item.project]) }

    private func popUp(_ menu: NSMenu?, from button: NSView?) {
        guard let menu, let button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    /// The Debug button is dimmed while a session is active (use the Debug panel to stop or step).
    func set(debugging: Bool) { buttons[Item.debug]?.isEnabled = !debugging }

    @objc private func morePressed() { popUp(moreMenu(), from: buttons[Item.more]) }
    @objc private func debugPressed() { onDebug() }
    @objc private func sidebar() { onToggleSidebar() }
    @objc private func inspector() { onToggleInspector() }
    @objc private func search() { onSearch() }
    @objc private func runPressed() { running ? onStop() : onRun() }
}
