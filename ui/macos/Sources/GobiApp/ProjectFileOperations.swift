import AppKit
import GobiModel

/// What Cut or Copy last took in the explorer. The file URLs are also on the general pasteboard, so Finder can paste them;
/// this keeps whether it was a cut, and is only believed while the pasteboard still holds the same files.
enum FileClipboard {
    static var urls: [URL] = []
    static var isCut = false
}

/// Explorer > Cut, Copy, Paste, Delete…, Refactor > Rename… and Move…. Everything stays inside the project folder.
extension ProjectWindowController {
    /// Moves one item to the Trash. Tests replace it so nothing reaches the real Trash.
    static var trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    // MARK: selection and safety

    /// The selected rows' URLs; a folder and something inside it selected together count once.
    func selectedURLs() -> [URL] {
        let urls = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
        return urls.filter { url in !urls.contains { $0 != url && FileOperations.isInside(url.path, root: $0.path) } }
    }

    /// The URL with the symlinks of its folders resolved (the item itself stays a link, so a link out of the project is not followed).
    private func resolved(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    /// True when `url` is inside the project folder, symlinks resolved.
    func isInsideProject(_ url: URL) -> Bool {
        FileOperations.isInside(resolved(url).path, root: root.resolvingSymlinksInPath().path)
    }

    private func fail(_ title: String, _ problems: [String]) {
        statusBar.set(note: "\(title): " + problems.joined(separator: "; "))
    }

    private func finish() {
        reloadExplorer()
        refreshGit()
    }

    // MARK: cut, copy, paste

    func copyToClipboard(_ urls: [URL], cut: Bool) {
        let inside = urls.filter(isInsideProject)
        guard !inside.isEmpty else { return }
        FileClipboard.urls = inside
        FileClipboard.isCut = cut
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(inside.map { $0 as NSURL })
        statusBar.set(note: (cut ? "Cut " : "Copied ") + (inside.count == 1 ? inside[0].lastPathComponent : "\(inside.count) items"))
    }

    /// The files to paste: the in-app clipboard when the pasteboard still holds the same files, else whatever files the pasteboard has.
    private func clipboardFiles() -> (urls: [URL], cut: Bool) {
        let onBoard = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !FileClipboard.urls.isEmpty, onBoard.map(\.path) == FileClipboard.urls.map(\.path) { return (FileClipboard.urls, FileClipboard.isCut) }
        return (onBoard, false)
    }

    var canPaste: Bool { !clipboardFiles().urls.isEmpty }

    /// Pastes into `folder`. Returns where the items went. A name already there gets a free one; a folder cannot go into itself.
    @discardableResult
    func paste(into folder: URL) -> [URL] {
        let (sources, cut) = clipboardFiles()
        guard !sources.isEmpty else { return [] }
        guard folder.path == root.path || isInsideProject(folder) else { fail("Paste", ["only the project folder can be pasted into"]); return [] }
        let manager = FileManager.default
        var made: [URL] = [], problems: [String] = []
        for source in sources {
            let name = source.lastPathComponent
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isFolder) else { problems.append("\(name) is gone"); continue }
            if isFolder.boolValue, FileOperations.isSameOrInside(folder.path, root: source.path) { problems.append("\(name) cannot go into itself"); continue }
            if cut, !isInsideProject(source) { problems.append("\(name) is outside the project"); continue }
            if cut, source.deletingLastPathComponent().path == folder.path { continue }   // already there
            let target = folder.appendingPathComponent(FileOperations.freeName(name, existing: (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []))
            do {
                if cut {
                    try manager.moveItem(at: source, to: target)
                    follow(from: source.path, to: target.path)
                } else {
                    try manager.copyItem(at: source, to: target)
                }
                made.append(target)
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        if cut, problems.isEmpty {
            FileClipboard.urls = []
            NSPasteboard.general.clearContents()
        }
        finish()
        if !problems.isEmpty { fail("Paste", problems) } else { statusBar.set(note: (cut ? "Moved " : "Pasted ") + (made.count == 1 ? made[0].lastPathComponent : "\(made.count) items")) }
        return made
    }

    // MARK: delete

    /// Moves the items to the Trash after asking (`confirmed` answers for tests). Open tabs of them close. Returns what was trashed.
    @discardableResult
    func deleteItems(_ urls: [URL], confirmed: Bool? = nil) -> [URL] {
        let items = urls.filter(isInsideProject)
        guard !items.isEmpty else { return [] }
        let tabPaths = items.flatMap { item in tabs.paths.filter { FileOperations.isSameOrInside($0, root: item.path) } }
        let unsaved = tabPaths.filter(tabs.isDirty).count
        let names = items.map(\.lastPathComponent)
        let go: Bool
        if let confirmed { go = confirmed } else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = FileOperations.deleteTitle(names: names)
            alert.informativeText = FileOperations.deleteDetail(names: names, unsaved: unsaved, openTabs: tabPaths.count)
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            go = alert.runModal() == .alertFirstButtonReturn
        }
        guard go else { return [] }
        var done: [URL] = [], problems: [String] = []
        for item in items {
            do {
                try Self.trashItem(item)
                for path in tabs.paths where FileOperations.isSameOrInside(path, root: item.path) { closeTab(path, force: true) }
                done.append(item)
            } catch {
                problems.append("\(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        finish()
        if !problems.isEmpty { fail("Delete", problems) } else { statusBar.set(note: "Moved " + (done.count == 1 ? done[0].lastPathComponent : "\(done.count) items") + " to the Trash") }
        return done
    }

    // MARK: rename and move

    /// Asks for a new name (or takes `typed`, for tests) and renames the file or folder. Returns the new URL, or nil when cancelled or refused.
    @discardableResult
    func renameItem(_ url: URL, to typed: String? = nil) -> URL? {
        guard isInsideProject(url) else { fail("Rename", ["only items inside the project can be renamed"]); return nil }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let old = url.lastPathComponent
        let answer: String
        if let typed { answer = typed } else {
            let field = NSTextField(string: old)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            let alert = NSAlert()
            alert.messageText = "Rename"
            alert.informativeText = old
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            let length = FileOperations.renameSelectionLength(old, isDirectory: isFolder.boolValue)
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { field.currentEditor()?.selectedRange = NSRange(location: 0, length: length) }
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            answer = field.stringValue
        }
        let name = answer.trimmingCharacters(in: .whitespaces)
        if name == old { return nil }
        let folder = url.deletingLastPathComponent()
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != old }
        if let problem = NewEntry.problem(with: name, existing: existing) {
            statusBar.set(note: "Rename: " + Self.describe(problem, name: name))
            return nil
        }
        return relocate(url, to: folder.appendingPathComponent(name), title: "Rename")
    }

    /// Moves the items into `folder` (a name already there gets a free one), the open tabs following. Returns where they went.
    @discardableResult
    func moveItems(_ urls: [URL], to folder: URL) -> [URL] {
        guard folder.path == root.path || isInsideProject(folder) else { fail("Move", ["the destination is outside the project"]); return [] }
        var moved: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue, FileOperations.isSameOrInside(folder.path, root: url.path) { fail("Move", ["\(url.lastPathComponent) cannot go into itself"]); continue }
            if url.deletingLastPathComponent().path == folder.path { continue }
            let name = FileOperations.freeName(url.lastPathComponent, existing: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            if let target = relocate(url, to: folder.appendingPathComponent(name), title: "Move") { moved.append(target) }
        }
        return moved
    }

    /// Asks for the destination folder (a pop-up of the project's folders, or Choose…) and moves the items there.
    func moveWithSheet(_ urls: [URL]) {
        let items = urls.filter(isInsideProject)
        guard !items.isEmpty else { return }
        let folders = projectFolders()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: folders.map(\.title))
        popup.addItem(withTitle: "Choose…")
        var chosen: URL? = nil
        let chooser = MenuAction { [weak self, weak popup] in
            guard let self, let popup else { return }
            if popup.indexOfSelectedItem < folders.count { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = self.root
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let url = panel.url, url.path == self.root.path || self.isInsideProject(url) { chosen = url }
            else { self.statusBar.set(note: "Move: choose a folder inside the project") }
            popup.selectItem(at: 0)
        }
        popup.target = chooser
        popup.action = #selector(MenuAction.fire(_:))
        let alert = NSAlert()
        alert.messageText = "Move"
        alert.informativeText = items.count == 1 ? "Move \(items[0].lastPathComponent) to" : "Move \(items.count) items to"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        withExtendedLifetime(chooser) {}
        let index = popup.indexOfSelectedItem
        moveItems(items, to: chosen ?? (index < folders.count ? folders[index].url : root))
    }

    /// The project's folders for the Move sheet: the project itself, then every folder below it by relative path (hidden ones left out).
    func projectFolders(limit: Int = 500) -> [(title: String, url: URL)] {
        var result: [(title: String, url: URL)] = [(root.lastPathComponent, root)]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL, result.count < limit {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { result.append((relativePath(of: url), url)) }
        }
        return result.sorted { $0.title < $1.title }.sorted { $0.url == root && $1.url != root }
    }

    /// Renames or moves one item on disk and makes the open tabs, breakpoints and recovery records follow.
    private func relocate(_ url: URL, to target: URL, title: String) -> URL? {
        guard !FileManager.default.fileExists(atPath: target.path) || url.lastPathComponent.lowercased() == target.lastPathComponent.lowercased() else {
            statusBar.set(note: "\(title): \(target.lastPathComponent) already exists")
            return nil
        }
        do {
            if url.lastPathComponent.lowercased() == target.lastPathComponent.lowercased(), url.deletingLastPathComponent() == target.deletingLastPathComponent() {
                // Only the letter case changes: go through a temporary name, since the volume may see both as one name.
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".gobi-rename-" + UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: target)
            } else {
                try FileManager.default.moveItem(at: url, to: target)
            }
        } catch {
            statusBar.set(note: "\(title): \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        follow(from: url.path, to: target.path)
        finish()
        return target
    }

    /// After `old` became `new` on disk: breakpoints move, and each open tab of it (or below it) is reopened at the new path
    /// in the same place of the tab strip, with its unsaved text and caret.
    func follow(from old: String, to new: String) {
        for move in FileOperations.retarget(from: old, to: new, paths: breakpoints.paths) { breakpoints.move(from: move.from, to: move.to) }
        UserDefaults.standard.set(breakpoints.encoded(), forKey: breakpointsKey)
        let activeBefore = tabs.active
        for move in FileOperations.retarget(from: old, to: new, paths: tabs.paths) {
            guard let pane = panes[move.from], let index = tabs.paths.firstIndex(of: move.from) else { continue }
            let text = pane.textView.string, caret = pane.textView.selectedRange(), edited = tabs.isDirty(move.from)
            closeTab(move.from, force: true)
            guard openFile(URL(fileURLWithPath: move.to)), let reopened = panes[move.to] else { continue }
            if edited { reopened.restoreUnsaved(text, changedOnDisk: false, quiet: true) }
            reopened.textView.setSelectedRange(NSRange(location: min(caret.location, (reopened.textView.string as NSString).length), length: 0))
            tabs.place(move.to, at: index)
        }
        if let activeBefore {
            let now = FileOperations.retarget(from: old, to: new, paths: [activeBefore]).first?.to ?? activeBefore
            if panes[now] != nil { activate(now) }
        }
    }
}

extension ProjectWindowController {
    /// ⌘V in the explorer: into the folder selected, next to the file selected, or the project folder.
    func pasteIntoSelection() {
        guard let url = selectedURLs().first else { paste(into: root); return }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        paste(into: isFolder.boolValue ? url : url.deletingLastPathComponent())
    }
}
