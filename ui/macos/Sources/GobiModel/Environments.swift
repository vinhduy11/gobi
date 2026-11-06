public struct EnvVar: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
    }
}

/// One environment profile of a project (Environments mock): variables, secret names (their values live in the Keychain), env
/// files, Go settings and safety switches.
public struct EnvProfile: Equatable, Sendable {
    public var name: String
    public var isDefault = false
    public var isRemote = false
    public var envFiles: [String] = []
    public var vars: [EnvVar] = []
    public var secretNames: [String] = []
    public var toolchain = ""
    public var tags = ""
    public var goflags = ""
    public var goos = ""
    public var goarch = ""
    public var confirmNonLocal = true
    public var blockDestructive = true

    public init(name: String) { self.name = name }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") && $0.isASCII }
    }
}

/// The `.gobi/environments.toml` file: profiles in order.
public struct EnvironmentFile: Equatable, Sendable {
    public var profiles: [EnvProfile] = []
    public init(profiles: [EnvProfile] = []) { self.profiles = profiles }

    public struct ParseError: Error, Equatable, CustomStringConvertible, Sendable {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    private enum Value { case string(String), bool(Bool), strings([String]), other }

    public static func parse(_ text: String) throws -> EnvironmentFile {
        var file = EnvironmentFile()
        var path: [String] = []
        func index(of name: String) -> Int {
            if let i = file.profiles.firstIndex(where: { $0.name == name }) { return i }
            file.profiles.append(EnvProfile(name: name))
            return file.profiles.count - 1
        }
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingSpaces()
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(line: number + 1, message: "a table header must end with ]") }
                path = line.dropFirst().dropLast().split(separator: ".").map { $0.trimmingSpaces() }
                if path.count >= 2, path[0] == "profiles" { _ = index(of: path[1]) }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw ParseError(line: number + 1, message: "expected key = value") }
            let key = line[line.startIndex ..< equals].trimmingSpaces()
            let value = try parseValue(String(line[line.index(after: equals)...]).trimmingSpaces(), line: number + 1)
            guard path.count >= 2, path[0] == "profiles" else { continue }
            let i = index(of: path[1])
            let section = path.count > 2 ? path[2] : ""
            switch (section, key, value) {
            case ("", "default", .bool(let b)): file.profiles[i].isDefault = b
            case ("", "remote", .bool(let b)): file.profiles[i].isRemote = b
            case ("", "env_files", .strings(let list)): file.profiles[i].envFiles = list
            case ("vars", _, .string(let v)): file.profiles[i].vars.append(EnvVar(name: key, value: v))
            case ("secrets", _, .bool(true)): file.profiles[i].secretNames.append(key)
            case ("go", "toolchain", .string(let v)): file.profiles[i].toolchain = v
            case ("go", "tags", .string(let v)): file.profiles[i].tags = v
            case ("go", "goflags", .string(let v)): file.profiles[i].goflags = v
            case ("go", "goos", .string(let v)): file.profiles[i].goos = v
            case ("go", "goarch", .string(let v)): file.profiles[i].goarch = v
            case ("safety", "confirm_non_local", .bool(let b)): file.profiles[i].confirmNonLocal = b
            case ("safety", "block_destructive", .bool(let b)): file.profiles[i].blockDestructive = b
            default: break   // keys this version does not know are kept out of the way, not an error
            }
        }
        return file
    }

    private static func parseValue(_ text: String, line: Int) throws -> Value {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text.hasPrefix("\"") { return .string(try parseString(text, line: line).value) }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw ParseError(line: line, message: "an array must end with ]") }
            var items: [String] = []
            var rest = Substring(text.dropFirst().dropLast()).trimmingSpaces()
            while !rest.isEmpty {
                let parsed = try parseString(rest, line: line)
                items.append(parsed.value)
                rest = String(rest.dropFirst(parsed.consumed)).trimmingSpaces()
                if rest.hasPrefix(",") { rest = String(rest.dropFirst()).trimmingSpaces() }
            }
            return .strings(items)
        }
        return .other
    }

    private static func parseString(_ text: String, line: Int) throws -> (value: String, consumed: Int) {
        guard text.hasPrefix("\"") else { throw ParseError(line: line, message: "expected a quoted string") }
        var out = ""
        var escaped = false
        var consumed = 1
        for character in text.dropFirst() {
            consumed += 1
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return (out, consumed)
            } else {
                out.append(character)
            }
        }
        throw ParseError(line: line, message: "a string is missing its closing quote")
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    public func toml() -> String {
        var out: [String] = ["# Environment profiles for Gobi. Secret values are not stored here: they are in the macOS Keychain."]
        for profile in profiles {
            out.append("")
            out.append("[profiles.\(profile.name)]")
            if profile.isDefault { out.append("default = true") }
            if profile.isRemote { out.append("remote = true") }
            if !profile.envFiles.isEmpty { out.append("env_files = [" + profile.envFiles.map(Self.quote).joined(separator: ", ") + "]") }
            if !profile.vars.isEmpty {
                out += ["", "[profiles.\(profile.name).vars]"] + profile.vars.map { "\($0.name) = \(Self.quote($0.value))" }
            }
            if !profile.secretNames.isEmpty {
                out += ["", "[profiles.\(profile.name).secrets]"] + profile.secretNames.map { "\($0) = true" }
            }
            let go = [("toolchain", profile.toolchain), ("tags", profile.tags), ("goflags", profile.goflags), ("goos", profile.goos), ("goarch", profile.goarch)].filter { !$0.1.isEmpty }
            if !go.isEmpty { out += ["", "[profiles.\(profile.name).go]"] + go.map { "\($0.0) = \(Self.quote($0.1))" } }
            out += ["", "[profiles.\(profile.name).safety]", "confirm_non_local = \(profile.confirmNonLocal)", "block_destructive = \(profile.blockDestructive)"]
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// The environment a profile gives a run: files first (later ones win), then the profile's variables, then secrets, then the Go
/// settings. Every value remembers where it came from.
public struct ResolvedEnvironment: Equatable, Sendable {
    private var entries: [String: (value: String, source: String)] = [:]
    public static func == (lhs: ResolvedEnvironment, rhs: ResolvedEnvironment) -> Bool { lhs.all == rhs.all }

    public func value(of name: String) -> String? { entries[name]?.value }
    public func source(of name: String) -> String? { entries[name]?.source }
    public var keys: [String] { entries.keys.sorted() }
    public var all: [String: String] { entries.mapValues(\.value) }
    mutating func set(_ name: String, _ value: String, source: String) { entries[name] = (value, source) }
}

public enum EnvResolver {
    public static func resolve(_ profile: EnvProfile, files: [String: String], secrets: [String: String]) -> ResolvedEnvironment {
        var result = ResolvedEnvironment()
        for file in profile.envFiles {
            for (name, value) in parseDotEnv(files[file] ?? "") { result.set(name, value, source: file) }
        }
        for variable in profile.vars { result.set(variable.name, variable.value, source: "profile") }
        for name in profile.secretNames { if let value = secrets[name] { result.set(name, value, source: "Keychain") } }
        let tags = profile.tags.split(whereSeparator: { $0 == " " || $0 == "," }).joined(separator: ",")
        let flags = [profile.goflags.trimmingSpaces(), tags.isEmpty ? "" : "-tags=" + tags].filter { !$0.isEmpty }
        if !flags.isEmpty { result.set("GOFLAGS", flags.joined(separator: " "), source: "profile") }
        if !profile.goos.isEmpty { result.set("GOOS", profile.goos, source: "profile") }
        if !profile.goarch.isEmpty { result.set("GOARCH", profile.goarch, source: "profile") }
        return result
    }

    /// KEY=VALUE lines with optional `export`, quotes and # comments (the same dialect gobid reads).
    static func parseDotEnv(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingSpaces()
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingSpaces() }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< equals].trimmingSpaces()
            guard EnvVar.isValidName(key) else { continue }
            var value = line[line.index(after: equals)...].trimmingSpaces()
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let hash = hashComment(in: value) {
                value = String(value[value.startIndex ..< hash]).trimmingSpaces()
            }
            pairs.append((key, value))
        }
        return pairs
    }

    private static func hashComment(in value: String) -> String.Index? {
        var previous: Character?
        for index in value.indices {
            if value[index] == "#", previous == " " { return value.index(before: index) }
            previous = value[index]
        }
        return nil
    }
}

public struct EnvTarget: Equatable, Sendable {
    public let component: String
    public let address: String
    public let source: String
    public let isLocal: Bool
}

/// Finds the services an environment points at (Resolved targets table) and says which are not on this machine.
public enum EnvTargets {
    private static let components: [(keyword: String, name: String, port: Int)] = [
        ("POSTGRES", "PostgreSQL", 5432), ("DB_", "PostgreSQL", 5432), ("PG", "PostgreSQL", 5432), ("MYSQL", "MySQL", 3306), ("MONGO", "MongoDB", 27017),
        ("REDIS", "Redis", 6379), ("KAFKA", "Kafka", 9092), ("MQTT", "MQTT", 1883), ("OPENSEARCH", "OpenSearch", 9200), ("ELASTIC", "OpenSearch", 9200),
    ]
    private static let hostSuffixes = ["_HOST"]
    private static let addressSuffixes = ["_URL", "_URI", "_DSN", "_ADDR", "_ADDRESS", "_BROKERS", "_SERVERS", "_ENDPOINT"]

    public static func find(in environment: ResolvedEnvironment) -> [EnvTarget] {
        var found: [String: EnvTarget] = [:]
        for key in environment.keys {
            guard let component = components.first(where: { key.hasPrefix($0.keyword) || key.contains("_" + $0.keyword) }) else { continue }
            guard let value = environment.value(of: key), !value.isEmpty else { continue }
            var host = "", port = 0
            if let suffix = hostSuffixes.first(where: { key.hasSuffix($0) }) {
                host = value
                port = Int(environment.value(of: String(key.dropLast(suffix.count)) + "_PORT") ?? "") ?? component.port
            } else if addressSuffixes.contains(where: { key.hasSuffix($0) }) {
                (host, port) = hostAndPort(of: value, defaultPort: component.port)
            } else { continue }
            guard !host.isEmpty, found[component.name] == nil else { continue }
            found[component.name] = EnvTarget(component: component.name, address: host + ":" + String(port), source: environment.source(of: key) ?? "", isLocal: isLocal(host: host))
        }
        return found.values.sorted { $0.component < $1.component }
    }

    public static func nonLocal(_ targets: [EnvTarget]) -> [EnvTarget] { targets.filter { !$0.isLocal } }

    static func hostAndPort(of value: String, defaultPort: Int) -> (String, Int) {
        var text = Substring(value)
        if let scheme = text.range(ofText: "://") { text = text[scheme.upperBound...] }
        if let at = text.lastIndex(of: "@"), !text[text.startIndex ..< at].contains("/") { text = text[text.index(after: at)...] }
        if let end = text.firstIndex(where: { $0 == "/" || $0 == "," || $0 == "?" || $0 == " " }) { text = text[text.startIndex ..< end] }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex) ..< close])
            let port = text[text.index(after: close)...].dropFirst().isEmpty ? defaultPort : Int(text[text.index(after: close)...].dropFirst()) ?? defaultPort
            return (host, port)
        }
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) { return (String(text[text.startIndex ..< colon]), port) }
        return (String(text), defaultPort)
    }

    public static func isLocal(host: String) -> Bool {
        let h = host.lowercased()
        return h.isEmpty || h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.")
    }
}

extension Substring {
    fileprivate func trimmingSpaces() -> String {
        var s = self
        while s.first == " " || s.first == "\t" || s.first == "\r" { s = s.dropFirst() }
        while s.last == " " || s.last == "\t" || s.last == "\r" { s = s.dropLast() }
        return String(s)
    }

    fileprivate func range(ofText needle: String) -> Range<Index>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var index = startIndex
        while let end = self.index(index, offsetBy: needle.count, limitedBy: endIndex) {
            if self[index ..< end] == needle { return index ..< end }
            if end == endIndex { break }
            index = self.index(after: index)
        }
        return nil
    }
}

extension String {
    fileprivate func trimmingSpaces() -> String { Substring(self).trimmingSpaces() }
}
