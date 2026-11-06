import AppKit
import GobiModel

/// The actions of the Edit, View, Build, Run, Git and Window menus that act on the front project window.
extension AppDelegate {
    // MARK: Git
    @objc func gitCommit(_ sender: Any?) { frontProject?.commitChanges() }
    @objc func gitPush(_ sender: Any?) { frontProject?.pushChanges() }
    @objc func gitUpdate(_ sender: Any?) { frontProject?.updateProject() }
    @objc func gitPull(_ sender: Any?) { frontProject?.pullChanges() }
    @objc func gitFetch(_ sender: Any?) { frontProject?.fetchChanges() }
    @objc func gitMerge(_ sender: Any?) { frontProject?.mergeIntoCurrent() }
    @objc func gitAbortMerge(_ sender: Any?) { frontProject?.abortMerge() }
    @objc func gitRebase(_ sender: Any?) { frontProject?.rebaseOntoChosenBranch() }
    @objc func gitAbortRebase(_ sender: Any?) { frontProject?.abortRebase() }
    @objc func gitContinueRebase(_ sender: Any?) { frontProject?.continueRebase() }
    @objc func gitSkipCommit(_ sender: Any?) { frontProject?.skipRebaseCommit() }
    @objc func gitResolveConflicts(_ sender: Any?) { frontProject?.resolveConflicts() }
    @objc func gitBranches(_ sender: Any?) { frontProject?.showBranches() }
    @objc func gitNewBranch(_ sender: Any?) { frontProject?.newBranch() }
    @objc func gitNewTag(_ sender: Any?) { frontProject?.newTag() }
    @objc func gitResetHead(_ sender: Any?) { frontProject?.resetHead() }
    @objc func gitNewWorktree(_ sender: Any?) { frontProject?.newWorktree() }
    @objc func gitWorktrees(_ sender: Any?) { frontProject?.showWorktrees() }
    @objc func gitShowLog(_ sender: Any?) { frontProject?.showGitLog() }
    @objc func gitCreatePatch(_ sender: Any?) { frontProject?.createPatch() }
    @objc func gitApplyPatch(_ sender: Any?) { frontProject?.applyPatch() }
    @objc func gitStash(_ sender: Any?) { frontProject?.stashChanges() }
    @objc func gitUnstash(_ sender: Any?) { frontProject?.unstashChanges() }
    @objc func gitRollBackAll(_ sender: Any?) { frontProject?.rollBackAll() }
    @objc func gitFileDiff(_ sender: Any?) { frontProject?.showCurrentFileDiff() }
    @objc func gitFileStage(_ sender: Any?) { frontProject?.toggleStageCurrentFile() }
    @objc func gitFileRollBack(_ sender: Any?) { frontProject?.rollBackCurrentFile() }
    @objc func gitManageRemotes(_ sender: Any?) { frontProject?.manageRemotes() }
    @objc func gitContinueRevert(_ sender: Any?) { frontProject?.continueRevert() }
    @objc func gitAbortRevert(_ sender: Any?) { frontProject?.abortRevert() }
    @objc func gitContinueCherryPick(_ sender: Any?) { frontProject?.continueCherryPick() }
    @objc func gitAbortCherryPick(_ sender: Any?) { frontProject?.abortCherryPick() }

    // MARK: Build and Run
    @objc func buildProject(_ sender: Any?) { frontProject?.buildProject() }
    @objc func buildModule(_ sender: Any?) { frontProject?.buildModule() }
    @objc func rebuildProject(_ sender: Any?) { frontProject?.rebuildProject() }
    @objc func stopRunning(_ sender: Any?) { frontProject?.stopEverything() }
    @objc func evaluateExpression(_ sender: Any?) { frontProject?.evaluateExpression() }
    @objc func viewBreakpoints(_ sender: Any?) { frontProject?.viewBreakpoints() }

    // MARK: Edit and View
    @objc func copyPath(_ sender: Any?) { frontProject?.copyCurrentPath() }
    @objc func sortLines(_ sender: Any?) { frontProject?.reorderSelectedLines(LineOrder.sorted) }
    @objc func reverseLines(_ sender: Any?) { frontProject?.reorderSelectedLines(LineOrder.reversed) }
    @objc func pastePlain(_ sender: Any?) { frontProject?.pastePlainText() }
    @objc func resetFontSize(_ sender: Any?) { EditorPreferences.update { $0.fontSize = EditorSettings().fontSize } }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        frontProject?.openFile(URL(fileURLWithPath: path))
    }

    @objc func clearRecentFiles(_ sender: Any?) { frontProject?.forgetRecentFiles() }

    /// Rebuilt each time View > Recent Files opens: the front project's last opened files, newest first.
    func fillRecentFiles(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = frontProject?.recentFiles ?? []
        for path in files {
            let entry = menu.addItem(withTitle: (path as NSString).lastPathComponent, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            entry.representedObject = path
            MenuIconImage.set("doc", on: entry)
            entry.toolTip = (path as NSString).abbreviatingWithTildeInPath
        }
        if files.isEmpty { let none = menu.addItem(withTitle: frontProject == nil ? "No Project Open" : "No Recent Files", action: nil, keyEquivalent: ""); none.isEnabled = false; MenuIconImage.set("minus.circle", on: none) }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        clear.isEnabled = !files.isEmpty
        MenuIconImage.set("trash", on: clear)
    }

    // MARK: Window
    @objc func newWindow(_ sender: Any?) { showWelcome() }
    @objc func nextProjectWindow(_ sender: Any?) { cycleProjectWindow(by: 1) }
    @objc func previousProjectWindow(_ sender: Any?) { cycleProjectWindow(by: -1) }

    /// Brings the next (or previous) open project window to the front, in the order the projects were opened.
    @discardableResult
    func cycleProjectWindow(by step: Int) -> ProjectWindowController? {
        let open = projects.filter { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        guard open.count > 1 else { return nil }
        let current = open.firstIndex { $0 === frontProject } ?? (step > 0 ? -1 : 0)
        let target = open[((current + step) % open.count + open.count) % open.count]
        if target.window?.isMiniaturized == true { target.window?.deminiaturize(nil) }
        target.window?.makeKeyAndOrderFront(nil)
        return target
    }

    /// The facts the newer menu items are enabled by, from the front project (or none).
    var menuContext: MenuContext {
        var context = frontProject?.menuContext ?? MenuContext()
        context.projectWindowCount = projects.filter { $0.window?.isVisible == true }.count
        return context
    }
}
