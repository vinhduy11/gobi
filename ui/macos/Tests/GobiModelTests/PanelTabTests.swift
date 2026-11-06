import Testing
@testable import GobiModel

@Suite("Bottom panel tab ids")
struct PanelTabTests {
    @Test func theOrderAndTitlesAreFixedData() {
        #expect(PanelTab.order.map(\.title) == ["Problems", "Tests", "Terminal", "Debug", "Profiler", "Diff", "Output", "Find"])
        #expect(PanelTab.order.map(\.rawValue) == ["problems", "tests", "terminal", "debug", "profiler", "diff", "output", "find"])
    }

    @Test func eachOldStoredIndexMapsToTheTabItWasThen() {
        for (index, tab) in PanelTab.order.enumerated() { #expect(PanelTab(legacyIndex: index) == tab) }
        #expect(PanelTab(legacyIndex: -1) == nil && PanelTab(legacyIndex: 99) == nil)
    }

    @Test func storedTextIsAnIdOrAnOldIndexAndAnythingElseFallsBackToProblems() {
        #expect(PanelTab(stored: "debug") == .debug)
        #expect(PanelTab(stored: "3") == .debug)
        #expect(PanelTab(stored: "7") == .find)
        #expect(PanelTab(stored: "usages-from-a-newer-build") == .problems)
        #expect(PanelTab(stored: "99") == .problems)
        #expect(PanelTab(stored: "") == .problems)
    }

    @Test func aSessionStoresTheIdAndReadsAnOldIndex() {
        var s = SessionState()
        s.bottomTab = .output
        #expect(s.encoded().contains("bottomTab=output"))
        #expect(SessionState.decode(s.encoded()).bottomTab == .output)
        #expect(SessionState.decode("bottomTab=2").bottomTab == .terminal)
    }
}
