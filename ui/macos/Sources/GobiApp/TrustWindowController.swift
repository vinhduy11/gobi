import AppKit

/// The workspace trust question, laid out as in the mock: what Restricted Mode keeps, what it turns off, the
/// parent-folder option and three buttons.
final class TrustWindowController: NSWindowController {
    enum Answer: Equatable {
        case trust(parentFolderToo: Bool)
        case restricted
        case cancel
    }

    private let parentBox: NSButton
    private(set) var answer: Answer = .cancel
    let projectName: String
    let parentName: String

    init(root: URL) {
        projectName = root.lastPathComponent
        let parent = root.deletingLastPathComponent()
        parentName = (parent.path as NSString).abbreviatingWithTildeInPath
        parentBox = NSButton(checkboxWithTitle: "Also trust projects in \(parentName)", target: nil, action: nil)
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled], backing: .buffered, defer: false))
        window?.title = "Workspace Trust"
        build()
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the question and returns the answer; closing it any other way counts as Cancel.
    func runModal() -> Answer {
        guard let window else { return .cancel }
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return answer
    }

    var headline: String { "Do you trust the authors of “\(projectName)”?" }

    func snapshotWindow(to path: String) { WindowSnapshot.write(window, to: path) }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        icon.setAccessibilityLabel("Gobi")

        let title = NSTextField(wrappingLabelWithString: headline)
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let explanation = NSTextField(wrappingLabelWithString: "Building, running or debugging a Go project can execute code from its files, such as go generate, cgo, tests and the toolchain line in go.mod.")
        explanation.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, explanation])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        let top = NSStackView(views: [icon, heading])
        top.alignment = .top
        top.spacing = 16

        func list(_ title: String, _ items: [String]) -> NSStackView {
            let header = NSTextField(labelWithString: title)
            header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let bullets = items.map { item -> NSTextField in
                let label = NSTextField(labelWithString: "•  " + item)
                label.textColor = .secondaryLabelColor
                return label
            }
            let stack = NSStackView(views: [header] + bullets)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            return stack
        }
        let keeps = list("In Restricted Mode, Gobi still gives you:", ["Editing, navigation and gopls diagnostics", "Git status and diff"])
        let turnsOff = list("and turns off:", ["Run, Debug, Test, Profile and terminals", "Environment profiles and tasks from .gobi", "Automatic Go toolchain downloads"])
        let details = NSStackView(views: [keeps, turnsOff])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 10
        details.edgeInsets = NSEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)

        parentBox.setAccessibilityLabel("Also trust projects in the parent folder")
        let boxRow = NSStackView(views: [parentBox])
        boxRow.edgeInsets = NSEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let restricted = NSButton(title: "Open in Restricted Mode", target: self, action: #selector(restrictedPressed))
        let trust = NSButton(title: "Trust and Open", target: self, action: #selector(trustPressed))
        trust.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, restricted, trust])

        let content = NSStackView(views: [top, details, NSView(), boxRow, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true
        top.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true
        window?.contentView = content
    }

    @objc private func trustPressed() { finish(.trust(parentFolderToo: parentBox.state == .on)) }
    @objc private func restrictedPressed() { finish(.restricted) }
    @objc private func cancelPressed() { finish(.cancel) }

    private func finish(_ result: Answer) {
        answer = result
        NSApp.stopModal()
    }
}
