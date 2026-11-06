/// What a usage request was made for. A result is stale once a document it came from has changed.
public struct UsageContext: Equatable {
    public var originURI: String
    public var position: LSPPosition
    public var symbol: String
    /// Version of each open document when the request was made.
    public var versions: [String: Int]
    /// Every file the result holds usages in (open or not).
    public var files: Set<String>

    public init(originURI: String, position: LSPPosition, symbol: String, versions: [String: Int], files: Set<String> = []) {
        self.originURI = originURI
        self.position = position
        self.symbol = symbol
        self.versions = versions
        self.files = files.union(versions.keys)
    }

    /// `currentVersion` answers the version of an open document, nil for a closed one. A file that was closed then and is open
    /// now counts as unchanged at its first version.
    public func isStale(currentVersion: (String) -> Int?) -> Bool {
        files.contains { uri in
            guard let now = currentVersion(uri) else { return false }
            return now != (versions[uri] ?? 1)
        }
    }
}

/// Asks for the symbols of many files, a few at a time. Single-threaded: `run`, the answers and `cancel` all happen on one thread
/// (the main thread). A new `run` or `cancel` voids every answer still on its way.
public final class SymbolFetchQueue {
    public struct Outcome: Equatable {
        public var symbols: [String: [DocumentSymbolInfo]]
        /// Files whose answer was an error or nothing; their usages are shown as file scope.
        public var failed: Set<String>
    }

    public let limit: Int
    private var generation = 0

    public init(limit: Int = 4) { self.limit = max(1, limit) }

    public func cancel() { generation += 1 }

    /// `fetch(uri, done)` must call `done` once, with nil for a failure. A second call for the same request is ignored.
    public func run(uris: [String], fetch: @escaping (String, @escaping ([DocumentSymbolInfo]?) -> Void) -> Void, finished: @escaping (Outcome) -> Void) {
        generation += 1
        let mine = generation
        var seen = Set<String>()
        let pending = uris.filter { seen.insert($0).inserted }
        var next = 0, inFlight = 0, pumping = false
        var outcome = Outcome(symbols: [:], failed: [])
        var done = false

        func pump() {
            guard !pumping else { return }
            pumping = true
            defer { pumping = false }
            while generation == mine, inFlight < limit, next < pending.count {
                let uri = pending[next]
                next += 1
                inFlight += 1
                var answered = false
                fetch(uri) { symbols in
                    guard self.generation == mine, !answered else { return }
                    answered = true
                    inFlight -= 1
                    if let symbols { outcome.symbols[uri] = symbols } else { outcome.failed.insert(uri) }
                    pump()
                }
            }
            if generation == mine, !done, next == pending.count, inFlight == 0 {
                done = true
                finished(outcome)
            }
        }
        pump()
    }
}

/// The source lines of the files a result has usages in, read once per file (off the main thread) before the table shows them.
/// The table only calls `line`; a call for something that is not stored counts as a miss.
public struct UsageLineCache {
    private var lines: [String: [Int: String]] = [:]
    private var loaded = Set<String>()
    /// Lookups the table made for lines that were not loaded; the self-test expects none.
    public private(set) var misses = 0

    public init() {}

    /// The paths still to read, without repeats.
    public func missing(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !loaded.contains($0) && seen.insert($0).inserted }
    }

    /// `lines` is nil for a file that could not be read; it is not asked for again.
    public mutating func store(path: String, lines stored: [Int: String]?) {
        loaded.insert(path)
        lines[path] = stored
    }

    public mutating func line(path: String, _ number: Int) -> String? {
        if let text = lines[path]?[number] { return text }
        misses += 1
        return nil
    }

    /// A stored line without counting a miss (used to check a line before opening it).
    public func peek(path: String, _ number: Int) -> String? { lines[path]?[number] }

    public func isLoaded(_ path: String) -> Bool { loaded.contains(path) }
}
