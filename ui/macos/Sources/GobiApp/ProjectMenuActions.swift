import AppKit
import GobiClient
import GobiModel

/// What the Git, Build and Run menus do in one project window. Each action that changes the repository has a plain entry point
/// (no dialog) that the dialog-driven menu action calls, so the self-test can run it.
extension ProjectWindowController {
    // MARK: what is enabled

    /// The facts `MenuAvailability` decides on.
    var menuContext: MenuContext {
        var context = MenuContext()
        context.hasProject = true
        context.isTrusted = isTrusted
        context.isRepository = !(gitStatus?.branch.isEmpty ?? true)
        context.hasEditor = currentPane != nil
        context.changedCount = gitStatus?.changedFiles.count ?? 0
        context.conflictCount = gitStatus?.conflictedFiles.count ?? 0
        context.operation = gitStatus?.operation
        context.branchCount = gitBranches.count
        if let url = currentPane?.editorFile.fileURL {
            let path = relativePath(of: url)
            context.currentFileChanged = gitStatus?.changedFiles.contains { $0.path == path } ?? false
        }
        context.debugActive = debugState.isActive
        context.debugPaused = debugState.canStep
        context.isRunning = isRunning
        return context
    }

    // MARK: running a git operation

    /// Runs a request, then looks at the repository again. A failure is shown in a sheet (a rebase that stops on a conflict explains
    /// itself in more than a status-bar line).
    func gitOperation(_ request: GitRequest, title: String, reloadFiles: Bool = false, then: ((Bool) -> Void)? = nil) {
        if request.changesWorkingTree { cancelAutoSaves() }
        git({ try $0.perform(request) }) { [weak self] result in
            guard let self else { return }
            defer { if request.changesWorkingTree { self.resumeAfterWorkingTreeChange() } }
            var succeeded = true
            if case .failure(let error) = result {
                succeeded = false
                self.statusBar.set(note: "git: \(error)")
                self.showFailure(title, "\(error)")
            } else {
                self.statusBar.set(note: title)
            }
            if reloadFiles { self.reloadExplorer(); self.checkDisk() }
            self.refreshGit()
            self.loadLog()
            then?(succeeded)
        }
    }

    private func showFailure(_ title: String, _ message: String) {
        guard let window, window.alphaValue > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(title) did not finish"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func askText(_ title: String, _ info: String, placeholder: String, button: String, initial: String = "") -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func confirm(_ title: String, _ info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func choose(_ title: String, _ info: String, items: [String], button: String) -> String? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        popup.addItems(withTitles: items)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.accessoryView = popup
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    // MARK: Git menu

    func updateProject() {
        cancelAutoSaves()
        git({ try $0.perform(.fetch); try $0.perform(.pull) }) { [weak self] result in
            if case .failure(let error) = result { self?.statusBar.set(note: "git: \(error)") } else { self?.statusBar.set(note: "Project updated") }
            self?.reloadExplorer()
            self?.resumeAfterWorkingTreeChange()
            self?.refreshGit()
        }
    }

    func showBranches() {
        guard let menu = branchMenu(), let view = window?.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: view.bounds.height - 70), in: view)
    }

    func showGitLog() {
        if sidebarView?.isHidden == true { toggleSidebar() }
        selectSidebarTab(Self.commitTabIndex)
        commitPanel.mode = .log
        loadLog()
    }

    func newTag() {
        guard let name = askText("New tag", "Marks the current commit.", placeholder: "v1.0.0", button: "Create"), !name.isEmpty else { return }
        tagHead(name)
    }

    func tagHead(_ name: String, then: ((Bool) -> Void)? = nil) { gitOperation(.tag(name), title: "Tagged \(name)", then: then) }

    func resetHead() {
        let mode = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        mode.addItems(withTitles: ["Mixed: keep the changes, unstage them", "Soft: keep the changes staged", "Hard: throw all changes away"])
        let target = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        target.stringValue = "HEAD"
        target.placeholderString = "HEAD~1, a commit or a tag"
        let box = NSStackView(views: [mode, target])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        let alert = NSAlert()
        alert.messageText = "Reset HEAD"
        alert.informativeText = "Moves the current branch to the commit below."
        alert.accessoryView = box
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let modes = ["mixed", "soft", "hard"]
        let chosen = modes[max(0, mode.indexOfSelectedItem)]
        let revision = target.stringValue.trimmingCharacters(in: .whitespaces)
        if chosen == "hard", !confirm("Throw away all changes?", "A hard reset to \(revision.isEmpty ? "HEAD" : revision) deletes every uncommitted change in the working tree. This cannot be undone.", button: "Reset Hard") { return }
        resetHead(mode: chosen, target: revision)
    }

    func resetHead(mode: String, target: String, then: ((Bool) -> Void)? = nil) {
        gitOperation(.reset(mode: mode, target: target), title: "Reset (\(mode))", reloadFiles: true, then: then)
    }

    func stashChanges() {
        guard let message = askText("Stash changes", "Saves the changes, new files included, and cleans the working tree.", placeholder: "Message (optional)", button: "Stash") else { return }
        stashChanges(message: message)
    }

    func stashChanges(message: String, then: ((Bool) -> Void)? = nil) { gitOperation(.stash(message), title: "Changes stashed", reloadFiles: true, then: then) }

    func confirmDropStash(_ index: Int) {
        guard confirm("Drop stash@{\(index)}?", "The stashed changes are deleted and cannot be brought back.", button: "Drop") else { return }
        gitOperation(.stashDrop(index), title: "Stash dropped")
    }

    func unstashChanges(then: ((Bool) -> Void)? = nil) { gitOperation(.unstash, title: "Stash applied", reloadFiles: true, then: then) }

    func abortMerge() {
        guard confirm("Abort the merge?", "The merge is undone and the files go back to how they were before it started.", button: "Abort Merge") else { return }
        gitOperation(.abortMerge, title: "Merge aborted", reloadFiles: true)
    }

    func rebaseOntoChosenBranch() {
        let others = gitBranches.filter { !$0.isCurrent }.map(\.name)
        guard let current = gitBranches.first(where: \.isCurrent)?.name, !others.isEmpty else { statusBar.set(note: "git: there is no other branch to rebase onto"); return }
        guard let branch = choose("Rebase \(current)", "Replays the commits of \(current) on top of the branch you pick. If they conflict, the rebase stays in progress: resolve the files, then Continue Rebase (or Skip Commit, or Abort Rebase).", items: others, button: "Rebase") else { return }
        rebase(onto: branch)
    }

    func rebase(onto branch: String, then: ((Bool) -> Void)? = nil) { gitOperation(.rebase(branch), title: "Rebased onto \(branch)", reloadFiles: true, then: then) }

    func abortRebase() {
        guard confirm("Abort the rebase?", "The branch goes back to how it was before the rebase started.", button: "Abort Rebase") else { return }
        gitOperation(.abortRebase, title: "Rebase aborted", reloadFiles: true)
    }

    func continueRebase() { gitOperation(.continueRebase, title: "Rebase continued", reloadFiles: true) }
    func skipRebaseCommit() { gitOperation(.skipRebase, title: "Commit skipped", reloadFiles: true) }
    func continueRevert() { gitOperation(.continueRevert, title: "Revert continued", reloadFiles: true) }
    func continueCherryPick() { gitOperation(.continueCherryPick, title: "Cherry-pick continued", reloadFiles: true) }

    func abortRevert() {
        guard confirm("Abort the revert?", "The revert is undone.", button: "Abort Revert") else { return }
        gitOperation(.abortRevert, title: "Revert aborted", reloadFiles: true)
    }

    func abortCherryPick() {
        guard confirm("Abort the cherry-pick?", "The cherry-pick is undone.", button: "Abort Cherry-Pick") else { return }
        gitOperation(.abortCherryPick, title: "Cherry-pick aborted", reloadFiles: true)
    }

    /// Lists the files in conflict in the status bar and opens the first one.
    @discardableResult
    func resolveConflicts() -> [String] {
        let files = (gitStatus?.conflictedFiles ?? []).map(\.path)
        guard let first = files.first else { statusBar.set(note: "No files in conflict"); return [] }
        openFile(root.appendingPathComponent(first))
        statusBar.set(note: "\(files.count) file\(files.count == 1 ? "" : "s") in conflict: " + files.joined(separator: ", "))
        return files
    }

    // MARK: patches

    func createPatch() {
        git({ try $0.patch() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.statusBar.set(note: "git: \(error)")
            case .success(let text):
                guard !text.isEmpty else { self.statusBar.set(note: "There are no changes to put in a patch"); return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "changes.patch"
                panel.message = "Saves every change since the last commit (new files that git does not know yet are not included)."
                guard panel.runModal() == .OK, let url = panel.url else { return }
                self.writePatch(text, to: url)
            }
        }
    }

    @discardableResult
    func writePatch(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusBar.set(note: "Patch saved to \(url.lastPathComponent)")
            return true
        } catch {
            statusBar.set(note: "Cannot save the patch: \(error.localizedDescription)")
            return false
        }
    }

    func applyPatch() {
        let panel = NSOpenPanel()
        panel.message = "Choose a patch file to apply to the working tree."
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPatch(file: url.path)
    }

    func applyPatch(file: String, then: ((Bool) -> Void)? = nil) { gitOperation(.applyPatch(file), title: "Patch applied", reloadFiles: true, then: then) }

    // MARK: rolling back

    /// Throws every uncommitted change away, after asking.
    func rollBackAll(confirmFirst: Bool = true) {
        let paths = (gitStatus?.changedFiles ?? []).map(\.path)
        guard !paths.isEmpty else { return }
        if confirmFirst, !confirm("Roll back all changes?", "\(paths.count) file\(paths.count == 1 ? "" : "s") go back to the last commit and untracked files are deleted. This cannot be undone.", button: "Roll Back All") { return }
        gitOperation(.discard(paths), title: "All changes rolled back", reloadFiles: true)
    }

    // MARK: current file

    var currentFileRelativePath: String? { currentPane.map { relativePath(of: $0.editorFile.fileURL) } }

    func showCurrentFileDiff() { currentFileRelativePath.map { showDiff(path: $0) } }

    /// Stages the open file when it has changes that are not staged, otherwise unstages it.
    func toggleStageCurrentFile() {
        guard let path = currentFileRelativePath, let file = gitStatus?.files.first(where: { $0.path == path }) else { return }
        let stage = file.unstaged || file.mark == .untracked
        gitAction(stage ? .stage([path]) : .unstage([path]))
    }

    func rollBackCurrentFile() { currentFileRelativePath.map { discardChanges($0) } }

    // MARK: remotes

    func manageRemotes() {
        git({ try $0.remotes() }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.statusBar.set(note: "git: \(error)")
            case .success(let remotes): self.showRemotesSheet(remotes)
            }
        }
    }

    private func showRemotesSheet(_ remotes: [GitRemote]) {
        let list = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        list.addItems(withTitles: remotes.map { "\($0.name)  \($0.url)" })
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        name.placeholderString = "Name for a new remote, for example origin"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        address.placeholderString = "Address of the new remote"
        let box = NSStackView(views: remotes.isEmpty ? [name, address] : [list, name, address])
        box.orientation = .vertical
        box.frame = NSRect(x: 0, y: 0, width: 320, height: remotes.isEmpty ? 56 : 90)
        let alert = NSAlert()
        alert.messageText = "Remotes"
        alert.informativeText = remotes.isEmpty ? "This repository has no remotes. Fill in both fields to add one." : "Pick a remote to remove, or fill in both fields to add one."
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        if !remotes.isEmpty { alert.addButton(withTitle: "Remove") }
        alert.addButton(withTitle: "Close")
        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            addRemote(name: name.stringValue.trimmingCharacters(in: .whitespaces), url: address.stringValue.trimmingCharacters(in: .whitespaces)) { [weak self] _ in self?.manageRemotes() }
        } else if answer == .alertSecondButtonReturn, !remotes.isEmpty, list.indexOfSelectedItem >= 0 {
            let remote = remotes[list.indexOfSelectedItem]
            guard confirm("Remove \(remote.name)?", "Forgets the remote and its remote-tracking branches. Nothing changes on the server.", button: "Remove") else { return manageRemotes() }
            removeRemote(remote.name) { [weak self] _ in self?.manageRemotes() }
        }
    }

    func addRemote(name: String, url: String, then: ((Bool) -> Void)? = nil) { gitOperation(.addRemote(name: name, url: url), title: "Remote \(name) added", then: then) }
    func removeRemote(_ name: String, then: ((Bool) -> Void)? = nil) { gitOperation(.removeRemote(name), title: "Remote \(name) removed", then: then) }

    // MARK: worktrees

    func newWorktree() {
        let folder = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        folder.stringValue = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-").path
        let branch = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        branch.placeholderString = "Branch"
        let create = NSButton(checkboxWithTitle: "Create the branch", target: nil, action: nil)
        create.state = .on
        let box = NSStackView(views: [folder, branch, create])
        box.orientation = .vertical
        box.alignment = .leading
        box.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        let alert = NSAlert()
        alert.messageText = "New worktree"
        alert.informativeText = "Checks a branch out in a second folder, so two branches can be open side by side. The folder must not exist yet."
        alert.accessoryView = box
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addWorktree(path: folder.stringValue.trimmingCharacters(in: .whitespaces), branch: branch.stringValue.trimmingCharacters(in: .whitespaces), create: create.state == .on)
    }

    func addWorktree(path: String, branch: String, create: Bool, then: ((Bool) -> Void)? = nil) {
        gitOperation(.addWorktree(path: path, branch: branch, create: create), title: "Worktree added at \(path)", then: then)
    }

    func removeWorktree(_ path: String, then: ((Bool) -> Void)? = nil) { gitOperation(.removeWorktree(path), title: "Worktree removed", then: then) }

    func showWorktrees() {
        git({ try $0.worktrees() }) { [weak self] result in
            guard let self else { return }
            guard case .success(let trees) = result, !trees.isEmpty else { self.statusBar.set(note: "git: cannot list the worktrees"); return }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
            popup.addItems(withTitles: trees.map(\.title))
            let alert = NSAlert()
            alert.messageText = "Worktrees"
            alert.informativeText = "Open one in its own window, or remove it (its files are deleted; the branch stays)."
            alert.accessoryView = popup
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Remove…")
            alert.addButton(withTitle: "Close")
            let answer = alert.runModal()
            guard popup.indexOfSelectedItem >= 0 else { return }
            let tree = trees[popup.indexOfSelectedItem]
            if answer == .alertFirstButtonReturn {
                (NSApp.delegate as? AppDelegate)?.openProject(URL(fileURLWithPath: tree.path))
            } else if answer == .alertSecondButtonReturn {
                if tree.path == self.root.path { self.statusBar.set(note: "git: the worktree you are in cannot be removed from itself"); return }
                if self.confirm("Remove this worktree?", "\(tree.path) is deleted from disk.", button: "Remove") { self.removeWorktree(tree.path) }
            }
        }
    }

    // MARK: Build and Run menus

    func buildProject() { begin(command: "build", packages: ["./..."], filter: "", arguments: [], tab: 6) }

    /// `go build` in the folder of the open file (the project folder when no file is open).
    func buildModule() {
        let package = currentPane.map { RunTarget.testPackage(forFile: relativePath(of: $0.editorFile.fileURL)) } ?? "."
        begin(command: "build", packages: [package], filter: "", arguments: [], tab: 6)
    }

    func rebuildProject() { begin(command: "build", packages: ["./..."], filter: "", arguments: ["-a"], tab: 6) }

    /// Run > Stop: the debug session when one is going, otherwise the run.
    func stopEverything() {
        if debugState.isActive { debugAction("stop") } else { stopRun() }
    }

    func evaluateExpression() {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 3)
        debugPanel.addWatchPressed()
    }

    func viewBreakpoints() {
        bottomPanel.isHidden = false
        bottomPanel.select(tab: 3)
        selectSidebarTab(3)
    }

    // MARK: Edit menu

    /// Copy Path: the open file's full path, or the project folder.
    func copyCurrentPath() { ContextMenus.copyToPasteboard(currentPane?.editorFile.fileURL.path ?? root.path) }

    /// Sort Lines and Reverse Lines: the selected lines (whole lines) are replaced in one edit, so one undo restores them.
    @discardableResult
    func reorderSelectedLines(_ order: (String) -> String) -> Bool {
        guard let textView = currentPane?.textView, textView.isEditable else { return false }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return false }
        let lines = text.lineRange(for: selection)
        let replacement = order(text.substring(with: lines))
        guard replacement != text.substring(with: lines), textView.shouldChangeText(in: lines, replacementString: replacement) else { return false }
        textView.replaceCharacters(in: lines, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
        return true
    }

    /// Paste as Plain Text: the pasteboard's text, without any formatting.
    @discardableResult
    func pastePlainText() -> Bool {
        guard let textView = currentPane?.textView, textView.isEditable, let text = NSPasteboard.general.string(forType: .string) else { return false }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        return true
    }

    // MARK: View > Recent Files

    private var recentFilesKey: String { "gobi.recentFiles." + root.path }

    var recentFiles: [String] {
        (UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    func recordRecentFile(_ url: URL) {
        let stored = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        UserDefaults.standard.set(RecentFiles.adding(url.path, to: stored), forKey: recentFilesKey)
    }

    func forgetRecentFiles() { UserDefaults.standard.removeObject(forKey: recentFilesKey) }
}
