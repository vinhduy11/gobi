// Text for the project window's status bar, breadcrumb and bottom panel tabs. Strings in, strings out.

public enum StatusBar {
    /// "Ln 28, Col 24": the caret position, one-based, from zero-based line and column.
    public static func caretText(line: Int, column: Int) -> String { "Ln \(line + 1), Col \(column + 1)" }

    public static func problemsTitle(count: Int) -> String { count > 0 ? "Problems \(count)" : "Problems" }

    /// "internal/server/server.go:28 · gopls": where a problem is and who reported it.
    public static func problemDetail(path: String, line: Int, source: String?) -> String {
        let place = "\(path):\(line + 1)"
        guard let source, !source.isEmpty else { return place }
        return place + " · " + source
    }

    /// The path of `file` under `projectRoot`, or the file's own path when it is outside.
    public static func relativePath(projectRoot: String, file: String) -> String {
        file.hasPrefix(projectRoot + "/") ? String(file.dropFirst(projectRoot.count + 1)) : file
    }

    public static func goplsText(connected: Bool, restricted: Bool) -> String {
        guard connected else { return "gopls starting…" }
        return restricted ? "gopls ready · Restricted" : "gopls ready"
    }
}

public enum LineEnding {
    /// "LF", "CRLF" or "CR": the first line break in the text; "LF" when there is none.
    public static func detect(_ text: [UInt16]) -> String {
        var index = 0
        while index < text.count {
            switch text[index] {
            case 0x0A: return "LF"
            case 0x0D: return index + 1 < text.count && text[index + 1] == 0x0A ? "CRLF" : "CR"
            default: index += 1
            }
        }
        return "LF"
    }
}

public enum Breadcrumb {
    /// The project folder's name, then each folder down to the file. A file outside the project shows its own folder and name.
    public static func segments(projectRoot: String, file: String) -> [String] {
        func parts(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
        let root = parts(projectRoot), path = parts(file)
        if path.count > root.count, Array(path.prefix(root.count)) == root {
            return [root.last ?? ""] + path.dropFirst(root.count)
        }
        return Array(path.suffix(2))
    }
}

public enum TerminalTitle {
    /// "zsh · hello": the shell's name and the project folder, as on the terminal tabs of the mock.
    public static func make(shellPath: String?, folder: String) -> String {
        let name = shellPath.flatMap { $0.split(separator: "/").last.map(String.init) } ?? ""
        return (name.isEmpty ? "shell" : name) + " · " + folder
    }

    /// Adds " 2", " 3" to repeated titles so tabs can be told apart.
    public static func numbered(_ titles: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { title in
            seen[title, default: 0] += 1
            return seen[title] == 1 ? title : "\(title) \(seen[title] ?? 1)"
        }
    }
}

public enum ShellQuote {
    /// The text in single quotes, with each inner single quote written as '\'' so the shell sees it as plain text.
    public static func single(_ text: String) -> String {
        "'" + text.replacingSingleQuotes() + "'"
    }

    /// nil when the text holds a line break, which would end the command early when typed into a terminal.
    public static func singleIfSafe(_ text: String) -> String? {
        text.contains("\n") || text.contains("\r") ? nil : single(text)
    }

    /// "cd '<folder>' && <command>", or nil when the folder cannot be quoted safely.
    public static func command(_ command: String, inFolder folder: String) -> String? {
        singleIfSafe(folder).map { "cd \($0) && \(command)" }
    }
}

extension String {
    fileprivate func replacingSingleQuotes() -> String {
        var result = ""
        for character in self { result += character == "'" ? "'\\''" : String(character) }
        return result
    }
}

/// The few facts the inspector shows from a go.mod file.
public struct GoModFacts: Equatable {
    public var module = ""
    public var goVersion = ""
    public var toolchain = ""

    public var shortName: String { module.split(separator: "/").last.map(String.init) ?? module }

    public static func parse(_ text: String) -> GoModFacts {
        var facts = GoModFacts()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine
            if let comment = commentStart(in: line) { line = line[line.startIndex ..< comment] }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let value = String(parts[1]).filter { $0 != "\"" }
            switch parts[0] {
            case "module": facts.module = value
            case "go": facts.goVersion = value
            case "toolchain": facts.toolchain = value
            default: break
            }
        }
        return facts
    }

    private static func commentStart(in line: Substring) -> Substring.Index? {
        var previous: Character?
        for index in line.indices {
            if line[index] == "/", previous == "/" { return line.index(before: index) }
            previous = line[index]
        }
        return nil
    }
}

public enum ToolbarText {
    /// "hello › go run ./cmd/hello": what Run would start, or just the project name when there is nothing to run.
    public static func runTarget(project: String, package: String?) -> String {
        guard let package else { return project }
        return project + " › go run " + package
    }

    public static func status(goplsReady: Bool, goVersion: String?, platform: String) -> String {
        var parts = [goplsReady ? "gopls ready" : "gopls starting…"]
        if let goVersion { parts.append("Go " + goVersion) }
        parts.append(platform)
        return parts.joined(separator: " · ")
    }

    /// "darwin/arm64" from uname's system and machine names.
    public static func platform(system: String, machine: String) -> String {
        let architecture: String
        switch machine {
        case "x86_64": architecture = "amd64"
        case "aarch64": architecture = "arm64"
        default: architecture = machine
        }
        return system.lowercased() + "/" + architecture
    }
}
