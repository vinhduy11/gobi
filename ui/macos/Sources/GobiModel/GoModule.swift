// Creating a go.mod for a bare folder, and running the Go files of a folder that has none. Strings in and out.

public enum GoModule {
    /// The folder name as a module path: lower case, ASCII letters, digits and `_ . ~` kept, every other run of characters one `-`.
    public static func moduleName(fromFolder folder: String) -> String {
        var name = ""
        for character in folder.lowercased() {
            let plain = character.isASCII && (character.isLetter || character.isNumber)
            if plain || character == "_" || character == "." || character == "~" {
                name.append(character)
            } else if name.last != "-" {
                name.append("-")
            }
        }
        while let first = name.first, first == "-" || first == "." { name.removeFirst() }
        while let last = name.last, last == "-" || last == "." { name.removeLast() }
        return name.isEmpty ? "app" : name
    }

    /// "1.26" from "1.26.5", "go1.25.1" or "1.25rc1"; nil when there is no major.minor.
    public static func majorMinor(of version: String) -> String? {
        var text = Substring(version)
        if text.hasPrefix("go") { text = text.dropFirst(2) }
        var parts: [String] = []
        var current = ""
        for character in text {
            if character.isASCII && character.isNumber { current.append(character); continue }
            if !current.isEmpty { parts.append(current); current = "" }
            if character != "." || parts.count >= 2 || parts.isEmpty { break }
        }
        if !current.isEmpty && parts.count < 2 { parts.append(current) }
        return parts.count == 2 ? parts.joined(separator: ".") : nil
    }

    public static func source(module: String, goVersion: String?) -> String {
        guard let goVersion, let short = majorMinor(of: goVersion) else { return "module \(module)\n" }
        return "module \(module)\n\ngo \(short)\n"
    }

    /// The folders (relative to the project root, "" for the root) where a go.mod would apply to a file in `directory`.
    public static func lookupFolders(forDirectory directory: String) -> [String] {
        var folders: [String] = []
        var parts = directory.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            folders.append(parts.joined(separator: "/"))
            parts.removeLast()
        }
        folders.append("")
        return folders
    }

    private static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if",
        "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]

    /// A name usable as a Go package: an identifier that is not a keyword.
    public static func isValidPackageName(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || (first.isASCII && first.isLetter), !keywords.contains(name) else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// The UserDefaults key under which "Not Now" is remembered for a project.
    public static func noticeKey(project: String) -> String { "gobi.noGoModNotice.\(project)" }
}

public enum SingleFileRun {
    public struct Sibling: Equatable, Sendable {
        public var name: String
        public var package: String
        public init(name: String, package: String) { self.name = name; self.package = package }
    }

    /// The name after `package` on the first code line, or nil.
    public static func packageName(inSource source: String) -> String? {
        var inBlockComment = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine)
            while let first = line.first, first == " " || first == "\t" || first == "\r" { line = line.dropFirst() }
            if inBlockComment {
                if line.contains("*/") { inBlockComment = false }
                continue
            }
            if line.hasPrefix("//") || line.isEmpty { continue }
            if line.hasPrefix("/*") { if !line.contains("*/") { inBlockComment = true }; continue }
            guard line.hasPrefix("package ") else { return nil }
            let name = line.dropFirst("package ".count).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "/" || $0 == ";" }).first
            return name.map(String.init)
        }
        return nil
    }

    /// The file `go run` is started from: `current` when it is a `package main` file, else the first (by name) `package main` file; nil when none.
    public static func mainFile(current: String?, siblings: [Sibling]) -> String? {
        if let current, siblings.contains(where: { $0.name == current && $0.package == "main" }) { return current }
        return siblings.filter { $0.name.hasSuffix(".go") && !$0.name.hasSuffix("_test.go") && $0.package == "main" }.map(\.name).sorted().first
    }

    /// The files `go run` (or `go test`, with `includeTests`) gets in place of `.` when there is no go.mod: the Go files of the folder in
    /// the package of `currentFile`, by name, each with `directory` in front.
    public static func arguments(currentFile: String, directory: String, siblings: [Sibling], includeTests: Bool) -> [String] {
        guard let current = siblings.first(where: { $0.name == currentFile }) else { return [prefixed(directory, currentFile)] }
        let wanted = base(current.package)
        let names = siblings.filter { sibling in
            sibling.name.hasSuffix(".go") && (includeTests || !sibling.name.hasSuffix("_test.go")) && base(sibling.package) == wanted
        }.map(\.name).sorted()
        return names.map { prefixed(directory, $0) }
    }

    private static func base(_ package: String) -> String { package.hasSuffix("_test") ? String(package.dropLast(5)) : package }
    private static func prefixed(_ directory: String, _ name: String) -> String { directory.isEmpty ? name : directory + "/" + name }
}
