import Testing
@testable import GobiModel

@Suite("Superseded replies")
struct RequestGateTests {
    @Test func theLatestRequestIsTheOnlyOneKept() {
        var gate = RequestGate()
        let first = gate.begin(version: 1)
        let second = gate.begin(version: 1)
        // The first reply arrives after the second request was sent: it is dropped, the second is kept.
        #expect(!gate.accepts(first, version: 1))
        #expect(gate.accepts(second, version: 1))
    }

    @Test func aReplyForAnOlderDocumentVersionIsDropped() {
        var gate = RequestGate()
        let ticket = gate.begin(version: 3)
        #expect(!gate.accepts(ticket, version: 4))
        #expect(gate.accepts(ticket, version: 3))
    }

    @Test func cancelDropsTheReplyInFlight() {
        var gate = RequestGate()
        let ticket = gate.begin(version: 1)
        gate.cancel()
        #expect(!gate.accepts(ticket, version: 1))
    }

    @Test func outOfOrderRepliesLeaveTheNewestAnswer() {
        var gate = RequestGate()
        var shown: [String] = []
        let a = gate.begin(version: 1), b = gate.begin(version: 1), c = gate.begin(version: 1)
        for (ticket, answer) in [(c, "c"), (a, "a"), (b, "b")] where gate.accepts(ticket, version: 1) { shown.append(answer) }
        #expect(shown == ["c"])
    }
}
