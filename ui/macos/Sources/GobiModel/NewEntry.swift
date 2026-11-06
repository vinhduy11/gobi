// The rules and templates of Explorer > New > File…, Folder…, Go File… and Go Test File…. Strings in and out.

public enum NewEntry {
    public enum Problem: Equatable, Sendable { case empty, hasSeparator, reserved, exists }

    /// Why `name` cannot be used for a new entry in a folder that already holds `existing`, or nil when it can.
    public static func problem(with name: String, existing: [String]) -> Problem? {
        let trimmed = trim(name)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") { return .hasSeparator }
        if trimmed == "." || trimmed == ".." { return .reserved }
        return existing.contains(trimmed) ? .exists : nil
    }

    /// `cart` and `cart.go` both give `cart.go`.
    public static func goFileName(_ typed: String) -> String {
        let name = trim(typed)
        return name.hasSuffix(".go") ? name : name + ".go"
    }

    /// `cart`, `cart.go`, `cart_test` and `cart_test.go` give `cart_test.go`.
    public static func goTestFileName(_ typed: String) -> String {
        var name = trim(typed)
        if name.hasSuffix(".go") { name.removeLast(3) }
        if name.hasSuffix("_test") { name.removeLast(5) }
        return name + "_test.go"
    }

    /// The package of the Go files already in the folder when there are some; else the folder's name made into a Go identifier
    /// (lower case, other characters `_`, a leading digit gets `pkg` in front); `main` for a folder without a usable name.
    public static func packageName(folder: String, sibling: String?) -> String {
        if let sibling, !sibling.isEmpty { return sibling }
        var name = ""
        for character in folder {
            if character.isLetter || character.isNumber || character == "_" { name.append(contentsOf: String(character).lowercased()) } else { name.append("_") }
        }
        if name.isEmpty || name.allSatisfy({ $0 == "_" }) { return "main" }
        if let first = name.first, first.isNumber { name = "pkg" + name }
        return name
    }

    public static func goSource(package: String) -> String { "package \(package)\n" }

    public static func goTestSource(package: String) -> String { "package \(package)\n\nimport \"testing\"\n" }

    private static func trim(_ text: String) -> String {
        var chars = Array(text)
        while let first = chars.first, first == " " || first == "\t" { chars.removeFirst() }
        while let last = chars.last, last == " " || last == "\t" { chars.removeLast() }
        return String(chars)
    }
}
