import AppKit
import GobiModel

/// Unsaved buffers kept under Application Support/Gobi/Recovery/<project>/<file>.txt, never inside the project.
/// They hold full unsaved text, so folders are 0700 and files 0600.
enum RecoveryStore {
    static var base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gobi/Recovery", isDirectory: true)

    static func folder(for root: URL) -> URL { base.appendingPathComponent(Recovery.key(root.path), isDirectory: true) }
    private static func file(_ root: URL, _ path: String) -> URL { folder(for: root).appendingPathComponent(Recovery.key(path) + ".txt") }

    private static func makePrivateFolder(_ url: URL) throws {
        let manager = FileManager.default
        for folder in [base, url] where !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes the record through a 0600 temporary file and a rename, so the text is never readable by others, not even briefly.
    /// Returns the reason when it could not be kept.
    @discardableResult
    static func save(_ record: RecoveryRecord, root: URL) -> String? {
        let url = file(root, record.path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try makePrivateFolder(url.deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: temporary.path, contents: Data(record.encoded().utf8), attributes: [.posixPermissions: 0o600]) else {
                return "the file could not be created"
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return String(cString: strerror(errno))
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func load(root: URL, path: String) -> RecoveryRecord? {
        (try? String(contentsOf: file(root, path), encoding: .utf8)).flatMap(RecoveryRecord.decode)
    }

    static func delete(root: URL, path: String) { try? FileManager.default.removeItem(at: file(root, path)) }

    /// Removes a project's whole folder (used by self-tests).
    static func clear(root: URL) { try? FileManager.default.removeItem(at: folder(for: root)) }

    /// At app start: drops records whose file is gone, that are older than 30 days or that cannot be read, tightens the permissions
    /// of the ones kept and removes empty project folders. Returns how many records it removed.
    @discardableResult
    static func prune(now: Date = Date()) -> Int {
        let manager = FileManager.default
        var removed = 0
        guard let projects = try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return 0 }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        for project in projects {
            let records = (try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
            var kept = 0
            for url in records {
                let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
                let age = Int(now.timeIntervalSince(modified) / 86_400)
                let record = (try? String(contentsOf: url, encoding: .utf8)).flatMap(RecoveryRecord.decode)
                if let record, !Recovery.shouldPrune(ageDays: age, fileExists: manager.fileExists(atPath: record.path)), !Recovery.isSensitive(record.path) {
                    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    kept += 1
                } else {
                    try? manager.removeItem(at: url)
                    removed += 1
                }
            }
            if kept == 0 { try? manager.removeItem(at: project) } else { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path) }
        }
        return removed
    }
}

extension ProjectWindowController {
    /// Keeps every edited buffer aside so the next open can bring it back. `onlyChanged` (the timer) skips buffers whose text
    /// is what the last write already holds. Files that look like secrets are never copied; a failed write shows in the status bar.
    func saveRecoveries(onlyChanged: Bool = false) {
        let dirty = tabs.dirtyPaths
        recoveryStamps = recoveryStamps.filter { dirty.contains($0.key) }
        for path in dirty where !Recovery.isSensitive(path) {
            guard let pane = openPane(for: path) else { continue }
            let text = pane.textView.string
            let stamp = text.hashValue
            if onlyChanged, recoveryStamps[path] == stamp { continue }
            // The signature is what the pane read or wrote last (not the disk now), so a change made meanwhile still shows on restore.
            let signature = pane.diskSignature ?? EditorPane.signature(of: pane.editorFile.fileURL)
            if let reason = RecoveryStore.save(RecoveryRecord(path: path, signature: signature, text: text), root: root) {
                statusBar.set(note: "Cannot keep unsaved changes of \((path as NSString).lastPathComponent): \(reason)")
            } else {
                recoveryStamps[path] = stamp
            }
        }
    }

    /// Deletes the kept buffer of a file that was saved, discarded or closed.
    func forgetRecovery(_ path: String) {
        recoveryStamps[path] = nil
        RecoveryStore.delete(root: root, path: path)
    }

    /// For each reopened tab with a kept buffer: put the text back (marked edited) and say so in the notice bar.
    /// Secret-looking files are not restored (and their record is removed).
    func restoreRecoveries(for session: SessionState) {
        for tab in session.tabs {
            guard let pane = openPane(for: tab.path), let record = RecoveryStore.load(root: root, path: tab.path) else { continue }
            if Recovery.isSensitive(tab.path) { RecoveryStore.delete(root: root, path: tab.path); continue }
            let url = pane.editorFile.fileURL
            let action = Recovery.action(saved: record.signature, disk: EditorPane.signature(of: url), diskDigest: { EditorPane.contentDigest(of: url) })
            if action == .drop || record.text == pane.textView.string { RecoveryStore.delete(root: root, path: tab.path); continue }
            pane.restoreUnsaved(record.text, changedOnDisk: action == .restoreChanged)
        }
    }
}
