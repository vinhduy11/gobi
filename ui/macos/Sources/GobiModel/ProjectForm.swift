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
    /// The stable name gobid takes in `project/new`.
    public var id: String
    public var title: String
    public var group: String
    public var summary: String
    public var isAvailable: Bool

    public init(id: String, title: String, group: String, summary: String, isAvailable: Bool) {
        self.id = id; self.title = title; self.group = group; self.summary = summary; self.isAvailable = isAvailable
    }

    /// The entries (field 1, repeated) of a project/templates result, in the order gobid numbers them.
    public static func parse(_ fields: [WireField]) -> [ProjectTemplate] {
        let entries: [(order: UInt64, template: ProjectTemplate)] = fields.filter { $0.number == 1 }.compactMap { field in
            guard let inner = try? WireField.parse(field.bytes) else { return nil }
            var template = ProjectTemplate(id: "", title: "", group: "", summary: "", isAvailable: false)
            var order: UInt64 = 0
            for item in inner {
                switch item.number {
                case 1: template.id = item.string
                case 2: order = item.uint
                case 3: template.group = item.string
                case 4: template.title = item.string
                case 5: template.summary = item.string
                case 6: template.isAvailable = item.uint != 0
                default: break
                }
            }
            return template.id.isEmpty ? nil : (order, template)
        }
        return entries.sorted { $0.order < $1.order }.map(\.template)
    }
}

public enum TemplateCatalog {
    /// The list and the groups of the New Project mock, used until gobid answers project/templates (or when it cannot).
    public static let fallback: [ProjectTemplate] = [
        ProjectTemplate(id: "cli", title: "Command-line tool", group: "Go module", summary: "A main package with a test, ready to run.", isAvailable: true),
        ProjectTemplate(id: "library", title: "Library", group: "Go module", summary: "A package other modules can import, with a test.", isAvailable: true),
        ProjectTemplate(id: "http", title: "HTTP service", group: "Service", summary: "A net/http server with a /healthz route and a test.", isAvailable: true),
        ProjectTemplate(id: "grpc", title: "gRPC service", group: "Service", summary: "A gRPC server with a health check. Not available yet: it needs generated code and downloaded modules.", isAvailable: false),
        ProjectTemplate(id: "consumer", title: "Message consumer", group: "Service", summary: "A worker that reads from a source in a loop, stops cleanly on Ctrl-C and has a handler you can test.", isAvailable: true),
        ProjectTemplate(id: "job", title: "Scheduled job", group: "Service", summary: "A job that runs once or on a timer, stops on Ctrl-C and exits with an error code when it fails.", isAvailable: true),
        ProjectTemplate(id: "workspace", title: "go.work (multi-module)", group: "Workspace", summary: "A go.work file with one module, ready for more.", isAvailable: true),
        ProjectTemplate(id: "empty", title: "Empty module", group: "Other", summary: "Only go.mod, for starting from nothing.", isAvailable: true),
        ProjectTemplate(id: "custom", title: "Custom templates…", group: "Other", summary: "Templates from your own folder. Not available yet.", isAvailable: false),
    ]

    /// What the dialog shows: gobid's list once it has answered, the fallback before that. Set from the main thread only.
    public private(set) static var all: [ProjectTemplate] = fallback

    /// Takes gobid's list; an empty one is ignored so the dialog never ends up with nothing to pick.
    public static func use(_ templates: [ProjectTemplate]) {
        all = templates.isEmpty ? fallback : templates
    }
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
