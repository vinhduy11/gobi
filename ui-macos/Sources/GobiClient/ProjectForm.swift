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
