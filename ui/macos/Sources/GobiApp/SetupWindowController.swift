import AppKit
import GobiClient
import GobiModel

/// The Setup check from the Setup mock: which tools Gobi uses are installed, with Install for the ones `go install` can fetch
/// and a hint for the rest. Nothing is downloaded until the user presses an Install button.
final class SetupWindowController: NSWindowController {
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let installAll = NSButton(title: "Install All Missing", target: nil, action: nil)
    private let checkAgain = NSButton(title: "Check Again", target: nil, action: nil)
    private let close = NSButton(title: "Continue", target: nil, action: nil)
    private(set) var tools: [ToolStatus] = []
    private var installing = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: "Some tools Gobi uses are missing")
        heading.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let explain = NSTextField(wrappingLabelWithString: "Gobi needs Go and gopls to edit and run Go code. Delve is needed only for debugging, and git for source control. Gobi can install the Go tools for you: it runs go install, which downloads from the internet, only after you press Install.")
        explain.textColor = .secondaryLabelColor
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        status.textColor = .secondaryLabelColor
        installAll.target = self; installAll.action = #selector(installAllPressed); installAll.bezelStyle = .rounded; installAll.keyEquivalent = "\r"
        checkAgain.target = self; checkAgain.action = #selector(reload); checkAgain.bezelStyle = .rounded
        close.target = self; close.action = #selector(closePressed); close.bezelStyle = .rounded
        let buttons = NSStackView(views: [status, NSView(), checkAgain, close, installAll])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, explain, list, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        window.contentView = stack
        for view in [explain, list, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Asks gobid which tools exist (off the main thread) and redraws.
    @objc func reload() {
        status.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> [ToolStatus] in
                let client = try ControlClient.connect()
                defer { client.close() }
                return try client.toolsCheck()
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let tools): self?.show(tools)
                case .failure(let error): self?.status.stringValue = "Cannot check: \(error)"
                }
            }
        }
    }

    func show(_ tools: [ToolStatus]) {
        self.tools = tools
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tool in tools { list.addArrangedSubview(row(for: tool)) }
        let fetchable = ToolStatus.installable(tools)
        installAll.isEnabled = !fetchable.isEmpty && !installing
        status.stringValue = ToolStatus.missing(tools).isEmpty ? "Everything is installed." : ""
        close.title = ToolStatus.needsAttention(tools) ? "Continue Without" : "Continue"
    }

    /// Titles of the Install buttons that are enabled, for the self-test.
    var installButtonTools: [String] { tools.filter { $0.installable && !$0.found }.map(\.name) }
    var installAllEnabled: Bool { installAll.isEnabled }
    var statusText: String { status.stringValue }

    private func row(for tool: ToolStatus) -> NSView {
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = tool.found ? .systemGreen : (tool.required ? .systemRed : .systemOrange)
        let name = NSTextField(labelWithString: tool.name)
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        name.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let detailText: String
        if tool.found { detailText = [tool.version, tool.path].filter { !$0.isEmpty }.joined(separator: " · ") }
        else { detailText = "Not found." + (tool.hint.isEmpty ? "" : " " + tool.hint) }
        let detail = NSTextField(labelWithString: detailText)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: tool.required ? "Required" : "Optional")
        kind.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        kind.textColor = .secondaryLabelColor
        var views: [NSView] = [dot, name, detail, NSView(), kind]
        if !tool.found && tool.installable {
            let button = NSButton(title: "Install", target: self, action: #selector(installOne(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.name)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = !installing
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 10
        return stack
    }

    @objc private func installOne(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        install([name])
    }

    @objc private func installAllPressed() { install(ToolStatus.installable(tools).map(\.name)) }

    /// Installs one after another off the main thread, reporting each in the status line, then checks again.
    func install(_ names: [String]) {
        guard !installing, !names.isEmpty else { return }
        installing = true
        installAll.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            for name in names {
                DispatchQueue.main.async { self?.status.stringValue = "Installing \(name)…" }
                do {
                    let client = try ControlClient.connect()
                    defer { client.close() }
                    try client.toolsInstall(name)
                } catch {
                    failure = "Could not install \(name): \(error)"
                    break
                }
            }
            DispatchQueue.main.async {
                self?.installing = false
                self?.reload()
                if let failure { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.status.stringValue = failure } }
            }
        }
    }

    @objc private func closePressed() { window?.close() }
}
