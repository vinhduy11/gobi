import AppKit
import GobiModel

/// Where a project's session (open tabs, carets, panel layout) is kept between launches.
enum SessionStore {
    static func key(for root: URL) -> String { "gobi.session." + root.path }

    static func load(for root: URL) -> SessionState? {
        guard let text = UserDefaults.standard.string(forKey: key(for: root)) else { return nil }
        return SessionState.decode(text)
    }

    static func save(_ state: SessionState, for root: URL) { UserDefaults.standard.set(state.encoded(), forKey: key(for: root)) }
    static func clear(for root: URL) { UserDefaults.standard.removeObject(forKey: key(for: root)); RecoveryStore.clear(root: root) }
}

extension ProjectWindowController {
    /// The tabs with their carets and the layout around the editor, as they are now.
    func currentSession() -> SessionState {
        var state = SessionState()
        for path in tabs.paths {
            let position = openPane(for: path).map { $0.editorFile.lineIndex.position(at: $0.textView.selectedRange().location) }
            state.tabs.append(SessionTab(path: path, line: position?.line ?? 0, character: position?.character ?? 0))
        }
        state.activePath = tabs.active
        state.bottomHidden = isBottomPanelHidden
        state.bottomTab = selectedPanelTab
        state.sidebarTab = sidebarTabIndex
        state.inspectorHidden = isInspectorHidden
        return state
    }

    func saveSession() { SessionStore.save(currentSession(), for: root) }

    /// Reopens what the last session had open. Files that are gone are dropped; kept unsaved edits come back marked as edited with a notice.
    func restoreSession() {
        guard let saved = SessionStore.load(for: root) else { return }
        apply(session: saved.keeping { FileManager.default.fileExists(atPath: $0) })
    }

    func apply(session: SessionState) {
        for tab in session.tabs where tab.path != session.activePath {
            if openFile(URL(fileURLWithPath: tab.path)) { openPane(for: tab.path)?.placeCaret(line: tab.line, character: tab.character) }
        }
        if let active = session.tabs.first(where: { $0.path == session.activePath }) {
            if openFile(URL(fileURLWithPath: active.path)) { currentPane?.reveal(line: active.line, character: active.character) }
        }
        selectSidebarTab(session.sidebarTab)
        setBottomPanel(hidden: session.bottomHidden, tab: session.bottomTab)
        setInspector(hidden: session.inspectorHidden)
        restoreRecoveries(for: session)
    }
}
