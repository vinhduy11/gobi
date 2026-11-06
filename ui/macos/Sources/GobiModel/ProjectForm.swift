// Quick checks for the New Project, Clone and Import forms, so a mistake shows before gobid is asked. gobid repeats
// every check; these only give early, readable feedback.

public enum ProjectForm {
    private static func isNameCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (ascii >= 48 && ascii <= 57) || (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
            || character == "." || character == "_" || character == "-"
    }

    private static func startsWithLetterOrDigit(_ text: String) -> Bool {
        guard let first = text.first, let ascii = first.asciiValue else { return false }
        return (ascii >= 48 && ascii <= 57) || (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }

    public static func problem(withName name: String) -> String? {
        if name.isEmpty { return "Enter a project name." }
        if name.count > 100 { return "The name is longer than 100 characters." }
        if !startsWithLetterOrDigit(name) || !name.allSatisfy(isNameCharacter) {
            return "Use letters, digits, '.', '_' and '-', starting with a letter or digit."
        }
        return nil
    }

    /// An empty module path is fine: gobid uses the project name.
    public static func problem(withModulePath path: String) -> String? {
        if path.isEmpty { return nil }
        let allowed = path.allSatisfy { isNameCharacter($0) || $0 == "/" || $0 == "~" }
        return startsWithLetterOrDigit(path) && allowed ? nil : "A module path uses letters, digits, '.', '_', '-' and '/'."
    }

    public static func problem(withCloneURL url: String) -> String? {
        if url.isEmpty { return "Enter the repository URL." }
        let hasSpace = url.contains(" ") || url.contains("\t") || url.contains("\n")
        let isScheme = ["https://", "ssh://", "git://"].contains { url.hasPrefix($0) && url.count > $0.count }
        let isScp = !url.hasPrefix("-") && url.contains("@") && url.contains(":") && !url.contains("://")
        if hasSpace || !(isScheme || isScp) { return "Use an https, ssh or git URL." }
        return nil
    }

    /// "https://host/acme/widget.git" and "git@host:acme/widget.git" give "widget".
    public static func repositoryName(fromURL url: String) -> String {
        var text = url
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last
    }
}

extension ProjectForm {
    /// What the Module path field offers before the user types one: example.com/<name>.
    public static func suggestedModulePath(forName name: String) -> String {
        name.isEmpty ? "" : "example.com/" + name
    }

    public static func commandSummary(modulePath: String) -> String {
        modulePath.isEmpty
            ? "Runs go mod init with the project name as the module path."
            : "Runs go mod init \(modulePath) with the selected toolchain."
    }
}

/// One entry of the template list in the New Project dialog.
public struct ProjectTemplate: Equatable {
    public var title: String
    public var group: String
    public var summary: String
    /// The template name gobid knows; empty when gobid cannot build it yet.
    public var coreID: String
    public var isAvailable: Bool { !coreID.isEmpty }
}

public enum TemplateCatalog {
    /// The list and the groups of the New Project mock, in order.
    public static let all: [ProjectTemplate] = [
        ProjectTemplate(title: "Command-line tool", group: "Go module", summary: "A main package with a test, ready to run.", coreID: "cli"),
        ProjectTemplate(title: "Library", group: "Go module", summary: "A package other modules can import, with a test.", coreID: "library"),
        ProjectTemplate(title: "HTTP service", group: "Go module", summary: "A net/http server with a /healthz route and a test.", coreID: "http"),
        ProjectTemplate(title: "gRPC service", group: "Go module", summary: "A gRPC server with a health check. Not available yet: it needs generated code and downloaded modules.", coreID: ""),
        ProjectTemplate(title: "Workspace go.work (multi-module)", group: "Go module", summary: "A go.work file with one module, ready for more.", coreID: "workspace"),
        ProjectTemplate(title: "Empty module", group: "Other", summary: "Only go.mod, for starting from nothing.", coreID: "empty"),
        ProjectTemplate(title: "Custom templates…", group: "Other", summary: "Templates from your own folder. Not available yet.", coreID: ""),
    ]
}

/// The "Will create" list of the New Project dialog, drawn as an indented tree.
public enum PreviewTree {
    public static func lines(root: String, files: [String]) -> [String] {
        var lines = [root + "/"]
        lines.append(contentsOf: children(of: files.map { $0.split(separator: "/").map(String.init) }, depth: 1))
        return lines
    }

    private static func children(of paths: [[String]], depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var folders: [String: [[String]]] = [:]
        var names: [String] = []
        for path in paths {
            if path.count > 1 { folders[path[0], default: []].append(Array(path.dropFirst())) } else if let name = path.first { names.append(name) }
        }
        var lines: [String] = []
        for folder in folders.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            lines.append(indent + folder + "/")
            lines.append(contentsOf: children(of: folders[folder] ?? [], depth: depth + 1))
        }
        for name in names.sorted(by: { $0.lowercased() < $1.lowercased() }) { lines.append(indent + name) }
        return lines
    }
}

extension ProjectForm {
    /// A Go identifier: a letter or underscore, then letters, digits and underscores (ASCII, which is what a rename dialog accepts).
    public static func isGoIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        func letter(_ scalar: Unicode.Scalar) -> Bool { scalar == "_" || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) }
        return letter(first) && text.unicodeScalars.allSatisfy { letter($0) || ($0.value >= 48 && $0.value <= 57) }
    }
}
