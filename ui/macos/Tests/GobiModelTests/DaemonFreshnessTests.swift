import Testing
@testable import GobiModel

@Suite("Stale daemon") struct DaemonFreshnessTests {
    @Test func aBinaryBuiltAfterTheDaemonStartedMeansTheDaemonIsStale() {
        #expect(DaemonFreshness.isStale(startedAt: 1_000, binaryModified: 1_060))
    }

    @Test func aDaemonStartedAfterTheBinaryWasBuiltIsFresh() {
        #expect(!DaemonFreshness.isStale(startedAt: 1_100, binaryModified: 1_060))
    }

    @Test func theSameSecondIsFresh() {
        #expect(!DaemonFreshness.isStale(startedAt: 1_060, binaryModified: 1_060))
    }

    @Test func anUnknownStartTimeIsNeverReplaced() {
        #expect(!DaemonFreshness.isStale(startedAt: 0, binaryModified: 1_060))
    }
}
