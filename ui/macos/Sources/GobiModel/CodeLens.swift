/// The code lens on Go declarations ("3 references · 1 implementation", "run test"): which lines are declarations and
/// what the lens says. Counts come from gopls; this file only reads source lines and words the result.

public enum LensAction: Equatable, Sendable { case references, implementations, runTest }

public struct LensSegment: Equatable, Sendable {
    public var text: String
    public var action: LensAction
}

public struct LensCounts: Equatable, Sendable {
    public var references: Int?
    public var implementations: Int?
}

public struct LensDeclaration: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case function, method, test, type, interface, interfaceMethod }
    public var qualifiedName: String   // "helper", "Dog.Speak", "Speaker.Speak": the cache key
    public var kind: Kind
    /// Where the declared name starts, for textDocument/references and /implementation.
    public var position: LSPPosition
}

public enum CodeLens {
    /// Lenses are made for this many declarations at most; the rest of a huge file gets none.
    public static let maximumPerFile = 200

    public static func declarations(in text: String) -> [LensDeclaration] {
        var found: [LensDeclaration] = []
        var interfaceName: String?
        var lineNumber = -1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if found.count >= maximumPerFile { break }
            if let owner = interfaceName {
                if line.hasPrefix("}") { interfaceName = nil; continue }
                if line.hasPrefix("\t"), let name = leadingIdentifier(line.dropFirst()), line.dropFirst(1 + name.count).hasPrefix("(") {
                    found.append(LensDeclaration(qualifiedName: owner + "." + name, kind: .interfaceMethod, position: LSPPosition(line: lineNumber, character: 1)))
                }
                continue
            }
            if line.hasPrefix("func ") {
                if let declaration = function(line, number: lineNumber) { found.append(declaration) }
            } else if line.hasPrefix("type "), let name = leadingIdentifier(line.dropFirst(5)) {
                let isInterface = line.dropFirst(5 + name.count).drop { $0 == " " }.hasPrefix("interface") && line.hasSuffix("{")
                found.append(LensDeclaration(qualifiedName: name, kind: isInterface ? .interface : .type, position: LSPPosition(line: lineNumber, character: 5)))
                if isInterface { interfaceName = name }
            }
        }
        return found
    }

    /// `func name(`, or `func (r *T) name(`.
    private static func function(_ line: Substring, number: Int) -> LensDeclaration? {
        var rest = line.dropFirst(5)
        var column = 5
        var receiver: String?
        if rest.hasPrefix("(") {
            guard let close = rest.firstIndex(of: ")") else { return nil }
            let inside = rest[rest.index(after: rest.startIndex) ..< close]
            let typeText = inside.split(separator: " ").last.map { $0.drop { $0 == "*" } } ?? ""
            receiver = leadingIdentifier(typeText)
            let after = rest[rest.index(after: close)...]
            let spaces = after.prefix { $0 == " " }.count
            column += rest.distance(from: rest.startIndex, to: close) + 1 + spaces
            rest = after.dropFirst(spaces)
        }
        guard let name = leadingIdentifier(rest), rest.dropFirst(name.count).first.map({ $0 == "(" || $0 == "[" }) == true else { return nil }
        if let receiver {
            return LensDeclaration(qualifiedName: receiver + "." + name, kind: .method, position: LSPPosition(line: number, character: column))
        }
        return LensDeclaration(qualifiedName: name, kind: TestAtCursor.isTestName(name) ? .test : .function, position: LSPPosition(line: number, character: column))
    }

    private static func leadingIdentifier(_ text: Substring) -> String? {
        let word = text.prefix { $0 == "_" || $0.isLetter || $0.isNumber }
        guard let first = word.first, !first.isNumber else { return nil }
        return String(word)
    }

    /// What the lens says; empty while the counts are still being fetched (a test needs none).
    public static func segments(for declaration: LensDeclaration, references: Int?, implementations: Int?) -> [LensSegment] {
        if declaration.kind == .test { return [LensSegment(text: "run test", action: .runTest)] }
        guard let references else { return [] }
        var segments = [LensSegment(text: count(references, "reference"), action: .references)]
        if declaration.kind == .interface || declaration.kind == .interfaceMethod, let implementations {
            segments.append(LensSegment(text: count(implementations, "implementation"), action: .implementations))
        }
        return segments
    }

    private static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)" + (number == 1 ? "" : "s") }
}

/// Counts already fetched, by declaration name and document version. Entries of older versions are dropped on the next store,
/// so the cache never outgrows one version's declarations.
public struct LensCache: Sendable {
    private var version = 0
    private var entries: [String: LensCounts] = [:]

    public init() {}

    public func counts(name: String, version: Int) -> LensCounts? { version == self.version ? entries[name] : nil }

    public mutating func store(name: String, version: Int, references: Int?, implementations: Int?) {
        if version != self.version { entries.removeAll(); self.version = version }
        var counts = entries[name] ?? LensCounts()
        if let references { counts.references = references }
        if let implementations { counts.implementations = implementations }
        entries[name] = counts
    }
}
