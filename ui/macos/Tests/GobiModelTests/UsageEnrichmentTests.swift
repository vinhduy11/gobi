import Testing
@testable import GobiModel

@Suite("Usage enrichment")
struct UsageEnrichmentTests {
    private func sym(_ uri: String) -> [DocumentSymbolInfo] {
        [DocumentSymbolInfo(uri: uri, name: "f", detail: "", kind: .function, range: (LSPPosition(line: 0, character: 0), LSPPosition(line: 9, character: 0)), selection: (LSPPosition(line: 0, character: 5), LSPPosition(line: 0, character: 6)), children: [], version: 1)]
    }

    /// A fetch that never answers by itself: the test completes each request when it likes.
    private final class Fake {
        var pending: [(uri: String, done: ([DocumentSymbolInfo]?) -> Void)] = []
        var started: [String] = []
        var inFlight = 0, peak = 0
        func fetch(_ uri: String, _ done: @escaping ([DocumentSymbolInfo]?) -> Void) {
            started.append(uri)
            inFlight += 1; peak = max(peak, inFlight)
            pending.append((uri, { [self] value in inFlight -= 1; done(value) }))
        }
        func answerAll(_ value: (String) -> [DocumentSymbolInfo]?) {
            while !pending.isEmpty { let next = pending.removeFirst(); next.done(value(next.uri)) }
        }
    }

    @Test func atMostFourFilesAreAskedAtOnceAcrossFiveHundred() {
        let fake = Fake(), queue = SymbolFetchQueue(limit: 4)
        let uris = (0 ..< 500).map { "file:///f\($0).go" }
        var result: SymbolFetchQueue.Outcome?
        queue.run(uris: uris, fetch: fake.fetch) { result = $0 }
        #expect(fake.inFlight == 4)
        while !fake.pending.isEmpty { let next = fake.pending.removeFirst(); next.done(sym(next.uri)) }
        #expect(fake.peak == 4 && fake.started.count == 500)
        #expect(result?.symbols.count == 500 && result?.failed.isEmpty == true)
    }

    @Test func aRepeatedFileIsAskedOnce() {
        let fake = Fake(), queue = SymbolFetchQueue(limit: 4)
        queue.run(uris: ["file:///a.go", "file:///a.go", "file:///b.go"], fetch: fake.fetch) { _ in }
        fake.answerAll { sym($0) }
        #expect(fake.started == ["file:///a.go", "file:///b.go"])
    }

    @Test func aFailingFileIsReportedAndTheOthersStillCome() {
        let fake = Fake(), queue = SymbolFetchQueue(limit: 2)
        var result: SymbolFetchQueue.Outcome?
        queue.run(uris: ["file:///a.go", "file:///bad.go", "file:///c.go"], fetch: fake.fetch) { result = $0 }
        fake.answerAll { $0.hasSuffix("bad.go") ? nil : sym($0) }
        #expect(result?.failed == ["file:///bad.go"])
        #expect(result?.symbols.keys.sorted() == ["file:///a.go", "file:///c.go"])
    }

    @Test func cancellingDropsEveryLateAnswerAndStopsAskingForMore() {
        let fake = Fake(), queue = SymbolFetchQueue(limit: 2)
        var finished = 0
        queue.run(uris: (0 ..< 6).map { "file:///f\($0).go" }, fetch: fake.fetch) { _ in finished += 1 }
        queue.cancel()
        fake.answerAll { sym($0) }
        #expect(finished == 0 && fake.started.count == 2)
    }

    @Test func aNewRunDiscardsTheWholePreviousGeneration() {
        let fake = Fake(), queue = SymbolFetchQueue(limit: 2)
        var first: SymbolFetchQueue.Outcome?, second: SymbolFetchQueue.Outcome?
        queue.run(uris: ["file:///a.go", "file:///b.go", "file:///c.go"], fetch: fake.fetch) { first = $0 }
        let late = fake.pending   // the first run's answers arrive after the rerun has started
        fake.pending = []
        queue.run(uris: ["file:///a.go"], fetch: fake.fetch) { second = $0 }
        for request in late { request.done(sym(request.uri)) }
        #expect(first == nil && second == nil && fake.started.count == 3)
        fake.answerAll { sym($0) }
        #expect(first == nil && second?.symbols.keys.sorted() == ["file:///a.go"])
    }

    @Test func noFilesFinishesAtOnce() {
        var result: SymbolFetchQueue.Outcome?
        SymbolFetchQueue(limit: 4).run(uris: [], fetch: { _, _ in Issue.record("asked") }) { result = $0 }
        #expect(result?.symbols.isEmpty == true)
    }

    @Test func aFetchThatAnswersTwiceCountsOnce() {
        let queue = SymbolFetchQueue(limit: 1)
        var answers: [([DocumentSymbolInfo]?) -> Void] = []
        var result: SymbolFetchQueue.Outcome?
        queue.run(uris: ["file:///a.go", "file:///b.go"], fetch: { _, done in answers.append(done) }) { result = $0 }
        answers[0](nil); answers[0](sym("x"))   // the second answer of the same request is ignored
        #expect(answers.count == 2 && result == nil)
        answers[1](sym("file:///b.go"))
        #expect(result?.failed == ["file:///a.go"] && result?.symbols.count == 1)
    }
}

@Suite("Usage line cache")
struct UsageLineCacheTests {
    @Test func aFileIsAskedForOnlyUntilItIsStored() {
        var cache = UsageLineCache()
        #expect(cache.missing(["a", "b", "a"]) == ["a", "b"])
        cache.store(path: "a", lines: [3: "x"])
        #expect(cache.missing(["a", "b"]) == ["b"])
        cache.store(path: "b", lines: nil)   // unreadable: still counts as loaded, so it is not read again
        #expect(cache.missing(["a", "b"]).isEmpty)
    }

    @Test func linesComeBackFromTheCacheAndMissesAreCounted() {
        var cache = UsageLineCache()
        cache.store(path: "a", lines: [3: "x"])
        #expect(cache.line(path: "a", 3) == "x")
        #expect(cache.misses == 0)
        #expect(cache.line(path: "a", 4) == nil && cache.line(path: "z", 0) == nil)
        #expect(cache.misses == 2)
    }
}
