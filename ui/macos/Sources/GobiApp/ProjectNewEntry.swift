import AppKit
import GobiModel

/// Explorer > New > File…, Folder…, Go File… and Go Test File….
extension ProjectWindowController {
    enum NewEntryKind {
        case file, folder, goFile, goTestFile

        var title: String {
            switch self {
            case .file: return "New File"
            case .folder: return "New Folder"
            case .goFile: return "New Go File"
            case .goTestFile: return "New Go Test File"
            }
        }
    }

    /// Asks for a name (or takes `name`, for tests), makes the file or folder in `folder`, refreshes the explorer and opens a new
    /// file. Returns where it was made, or nil when cancelled or refused (the status bar says why).
    @discardableResult
    func newEntry(_ kind: NewEntryKind, in folder: URL, name: String? = nil) -> URL? {
        let typed: String
        if let name { typed = name } else {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = kind == .folder ? "folder name" : (kind == .file ? "file name" : "name, for example cart")
            let alert = NSAlert()
            alert.messageText = kind.title
            alert.informativeText = "In \(relativeFolder(folder))"
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            typed = field.stringValue
        }
        let fileName: String
        switch kind {
        case .file, .folder: fileName = typed.trimmingCharacters(in: .whitespaces)
        case .goFile: fileName = NewEntry.goFileName(typed)
        case .goTestFile: fileName = NewEntry.goTestFileName(typed)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if let problem = NewEntry.problem(with: fileName, existing: existing) {
            statusBar.set(note: "\(kind.title): " + Self.describe(problem, name: fileName))
            return nil
        }
        let url = folder.appendingPathComponent(fileName)
        do {
            switch kind {
            case .folder:
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case .file:
                try Data().write(to: url)
            case .goFile, .goTestFile:
                let package = NewEntry.packageName(folder: folder.lastPathComponent, sibling: packageOfGoFiles(in: folder, among: existing))
                let source = kind == .goFile ? NewEntry.goSource(package: package) : NewEntry.goTestSource(package: package)
                try source.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            statusBar.set(note: "\(kind.title): \(error.localizedDescription)")
            return nil
        }
        reloadExplorer()
        if kind != .folder { openFile(url) }
        return url
    }

    private static func describe(_ problem: NewEntry.Problem, name: String) -> String {
        switch problem {
        case .empty: return "type a name"
        case .hasSeparator: return "a name cannot contain /"
        case .reserved: return "\(name) is not a usable name"
        case .exists: return "\(name) already exists"
        }
    }

    private func relativeFolder(_ folder: URL) -> String {
        let path = StatusBar.relativePath(projectRoot: root.path, file: folder.path)
        return path.isEmpty || path == folder.path ? root.lastPathComponent : root.lastPathComponent + "/" + path
    }

    /// The `package` of the first Go file in the folder (a test file's `_test` suffix left off), or nil when there is none.
    private func packageOfGoFiles(in folder: URL, among names: [String]) -> String? {
        for name in names.sorted() where name.hasSuffix(".go") {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("package ") {
                var package = line.dropFirst("package ".count).split(separator: " ").first.map(String.init) ?? ""
                if package.hasSuffix("_test") { package.removeLast(5) }
                if !package.isEmpty { return package }
            }
        }
        return nil
    }
}
