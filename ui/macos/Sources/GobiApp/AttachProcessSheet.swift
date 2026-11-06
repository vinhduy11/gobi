import AppKit
import GobiModel

/// The Attach to Process sheet (Debug dialogs mock): the running processes with a filter box.
final class AttachProcessSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let table = NSTableView()
    private let filter = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let attachButton = NSButton(title: "Attach", target: nil, action: nil)
    private var all: [ProcessRow] = []
    private(set) var rows: [ProcessRow] = []
    var onAttach: (Int) -> Void = { _ in }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: "Attach to a running Go process")
        heading.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let note = NSTextField(wrappingLabelWithString: "Delve attaches to the process you pick. macOS may ask for permission.")
        note.textColor = .secondaryLabelColor
        filter.placeholderString = "Filter by name or number…"
        filter.delegate = self
        for (id, title, width) in [("pid", "PID", 80), ("name", "Name", 380)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(attachPressed)
        table.target = self
        table.setAccessibilityLabel("Processes")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        attachButton.target = self
        attachButton.action = #selector(attachPressed)
        attachButton.keyEquivalent = "\r"
        status.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [status, NSView(), cancel, attachButton])
        let stack = NSStackView(views: [heading, note, filter, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        window.contentView = stack
        for view in [note, filter, scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lists the processes (`ps`) off the main thread.
    func load() {
        status.stringValue = "Looking up processes…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let output: String
            if (try? process.run()) != nil {
                output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
            } else { output = "" }
            DispatchQueue.main.async { self?.show(ProcessRow.parse(output)) }
        }
    }

    func show(_ processes: [ProcessRow]) {
        all = processes
        applyFilter()
        status.stringValue = processes.isEmpty ? "No processes found." : ""
    }

    private func applyFilter() {
        rows = ProcessRow.filter(all, by: filter.stringValue)
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func attachPressed() {
        guard table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else { return }
        let pid = rows[table.selectedRow].pid
        close(sheet: true)
        onAttach(pid)
    }

    @objc private func cancelPressed() { close(sheet: true) }

    private func close(sheet: Bool) {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: tableColumn?.identifier.rawValue == "pid" ? String(rows[row].pid) : rows[row].name)
    }
}
