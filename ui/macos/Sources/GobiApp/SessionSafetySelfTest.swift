import AppKit
import GobiModel

extension AppDelegate {
    /// Part of `--selftest-session`: auto save never overwrites a newer file, closing a window is all-or-nothing, a content change
    /// with equal metadata is noticed, and kept buffers are private. `first` and `second` are existing Go files of the folder.
    func runSessionSafetyChecks(root: URL, first: URL, second: URL, check: (String, Bool) -> Void, addCleanup: (@escaping () -> Void) -> Void) {
        func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        let originals = [first, second].map { (url: $0, text: text($0)) }
        let savedPreferences = EditorPreferences.current
        addCleanup {
            EditorPreferences.current = savedPreferences
            for item in originals { try? item.text.write(to: item.url, atomically: true, encoding: .utf8) }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".env"))
            RecoveryStore.clear(root: root)
        }

        // Auto save does not run over a file that changed on disk.
        EditorPreferences.update { $0.autoSave = .afterDelay }
        let window = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        window.showWindow(nil)
        window.openFile(first)
        let pane = window.openPane(for: first.path)
        pane?.textView.insertText("// mine\n", replacementRange: NSRange(location: 0, length: 0))
        let theirs = "package main\n// theirs, written while auto save waited\n"
        try? theirs.write(to: first, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: first.path)
        wait(ProjectWindowController.autoSaveDelay + 0.8)
        check("auto save leaves a file that changed on disk alone", text(first) == theirs && pane?.editorFile.isEdited == true)
        check("and the conflict notice asks (\(pane?.editor.noticeActionTitles ?? []))", pane?.editor.noticeActionTitles == ["Reload from Disk", "Keep Mine"])
        check("a second automatic save still waits for the answer", pane?.save(automatic: true) == false && text(first) == theirs)
        pane?.editor.pressNotice("Keep Mine")
        check("an explicit save after Keep Mine overwrites", pane?.save() == true && text(first) == pane?.textView.string)

        // A git operation cancels the pending timer and the buffer is checked afterwards.
        pane?.textView.insertText("// again\n", replacementRange: NSRange(location: 0, length: 0))
        window.cancelAutoSaves()
        let rewritten = "package main\n// rewritten by git\n"
        try? rewritten.write(to: first, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(40)], ofItemAtPath: first.path)
        wait(ProjectWindowController.autoSaveDelay + 0.5)
        check("a cancelled auto save does not write", text(first) == rewritten)
        window.resumeAfterWorkingTreeChange()
        check("afterwards the edited buffer gets the conflict notice", pane?.editor.noticeActionTitles == ["Reload from Disk", "Keep Mine"])
        wait(ProjectWindowController.autoSaveDelay + 0.5)
        check("and is still not overwritten", text(first) == rewritten)
        pane?.editor.pressNotice("Reload from Disk")
        EditorPreferences.update { $0.autoSave = .off }

        // Equal size, time and (in place) the same file, other content: only the digest tells.
        try? originals[0].text.write(to: first, atomically: true, encoding: .utf8)
        pane?.reloadFromDisk()
        let before = EditorPane.signature(of: first)
        var stamp = stat()
        stat(first.path, &stamp)
        let changedInPlace = text(first).replacingOccurrences(of: "package", with: "packagX")
        if let handle = try? FileHandle(forWritingTo: first) { handle.write(Data(changedInPlace.utf8)); try? handle.close() }
        // Put back the exact modification time (a Date loses the nanoseconds).
        var times = [stamp.st_atimespec, stamp.st_mtimespec]
        utimensat(AT_FDCWD, first.path, &times, 0)
        check("the test file looks unchanged by its metadata", EditorPane.signature(of: first) == before && text(first) == changedInPlace)
        _ = pane?.checkDisk(verifyContent: false)
        check("the cheap poll does not read it (no reload)", pane?.textView.string == originals[0].text)
        window.checkDisk()
        check("a check after an event compares the content and reloads", pane?.textView.string == changedInPlace)
        window.window?.close()

        // Closing the window is all-or-nothing.
        let closing = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        closing.showWindow(nil)
        try? originals[0].text.write(to: first, atomically: true, encoding: .utf8)
        closing.openFile(first)
        closing.openFile(second)
        closing.startWatchingDisk()
        let paneOne = closing.openPane(for: first.path), paneTwo = closing.openPane(for: second.path)
        paneOne?.textView.insertText("// one\n", replacementRange: NSRange(location: 0, length: 0))
        paneTwo?.textView.insertText("// two\n", replacementRange: NSRange(location: 0, length: 0))
        let textOne = paneOne?.textView.string, textTwo = paneTwo?.textView.string
        let record = RecoveryRecord(path: first.path, signature: nil, text: "kept")
        RecoveryStore.save(record, root: root)
        var asked: [String] = []
        closing.saveAnswerHook = { name in
            asked.append(name)
            return asked.count == 1 ? .discard : .cancel
        }
        let allowed = closing.windowShouldClose(closing.window!)
        check("Don't Save then Cancel keeps the window (asked \(asked))", !allowed && asked.count == 2)
        check("both tabs and their text are intact", closing.tabs.paths.count == 2 && paneOne?.textView.string == textOne && paneTwo?.textView.string == textTwo && closing.isDirty(first) && closing.isDirty(second))
        check("the kept buffer and the watchers are untouched", RecoveryStore.load(root: root, path: first.path) == record && closing.isWatchingDisk)
        check("nothing was written to the files", text(first) == originals[0].text && text(second) == originals[1].text)
        closing.saveAnswerHook = { _ in .discard }
        check("answering every question lets the window close and stops the watchers", closing.windowShouldClose(closing.window!) && !closing.isWatchingDisk && closing.tabs.paths.isEmpty)
        closing.window?.close()

        // Kept buffers: private, never for secret-looking files, pruned when stale.
        let secret = root.appendingPathComponent(".env")
        try? "TOKEN=1\n".write(to: secret, atomically: true, encoding: .utf8)
        let keeper = ProjectWindowController(root: root, kind: .module, isTrusted: true)
        keeper.showWindow(nil)
        keeper.openFile(first)
        keeper.openFile(secret)
        keeper.openPane(for: first.path)?.textView.insertText("// private\n", replacementRange: NSRange(location: 0, length: 0))
        keeper.openPane(for: secret.path)?.textView.insertText("TOKEN=2\n", replacementRange: NSRange(location: 0, length: 0))
        keeper.saveRecoveries()
        let folder = RecoveryStore.folder(for: root)
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        check("kept buffers are 0600 in a 0700 folder (\(String(mode(folder), radix: 8)), \(files.map { String(mode($0), radix: 8) }))", mode(folder) == 0o700 && !files.isEmpty && files.allSatisfy { mode($0) == 0o600 })
        check("a secret-looking file's text is not kept", RecoveryStore.load(root: root, path: secret.path) == nil && RecoveryStore.load(root: root, path: first.path) != nil)
        keeper.window?.close()

        let savedBase = RecoveryStore.base
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gobi-prune-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        RecoveryStore.base = scratch
        addCleanup { RecoveryStore.base = savedBase; try? FileManager.default.removeItem(at: scratch) }
        RecoveryStore.save(RecoveryRecord(path: first.path, signature: nil, text: "live"), root: root)
        RecoveryStore.save(RecoveryRecord(path: root.appendingPathComponent("gone.go").path, signature: nil, text: "orphan"), root: root)
        let pruned = RecoveryStore.prune()
        check("pruning removes the record of a missing file only (\(pruned))", pruned == 1 && RecoveryStore.load(root: root, path: first.path) != nil)
        let old = Date().addingTimeInterval(-40 * 86_400)
        let liveFile = RecoveryStore.folder(for: root).appendingPathComponent(Recovery.key(first.path) + ".txt")
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: liveFile.path)
        check("and a record older than 30 days", RecoveryStore.prune() == 1 && RecoveryStore.load(root: root, path: first.path) == nil)
        RecoveryStore.base = savedBase
        EditorPreferences.current = savedPreferences
    }
}
