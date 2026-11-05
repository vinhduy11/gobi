import Testing
@testable import GobiClient

@Suite("Pending replies")
struct PendingRepliesTests {
    @Test func timedOutRequestIsForgottenSoALateReplyFindsNothing() {
        var pending = PendingReplies<String>()
        var calls = 0
        pending.add(7) { _ in calls += 1 }
        #expect(pending.count == 1)
        // The waiter gives up after its timeout and removes the entry.
        #expect(pending.take(7) != nil)
        #expect(pending.count == 0)
        // The late response finds no handler to call.
        #expect(pending.take(7) == nil)
        #expect(calls == 0)
    }

    @Test func takeAllReturnsEveryPendingHandlerOnce() {
        var pending = PendingReplies<Int>()
        pending.add(1) { _ in }
        pending.add(2) { _ in }
        #expect(pending.takeAll().count == 2)
        #expect(pending.count == 0)
    }
}
