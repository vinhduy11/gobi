import Testing
@testable import GobiModel

@Suite("Session and disk changes")
struct SessionTests {
    private func sample() -> SessionState {
        var s = SessionState()
        s.tabs = [SessionTab(path: "/p/main.go", line: 12, character: 4), SessionTab(path: "/p/with space/a=b.go", line: 0, character: 0)]
        s.activePath = "/p/main.go"
        s.bottomHidden = true
        s.bottomTab = .debug
        s.sidebarTab = 1
        s.inspectorHidden = true
        return s
    }

    @Test func aSessionRoundTripsThroughText() {
        #expect(SessionState.decode(sample().encoded()) == sample())
        #expect(SessionState.decode("") == SessionState())
        #expect(SessionState.decode("garbage\ntab=x,y,z\nbottomTab=abc") == SessionState())
    }

    @Test func missingFilesAreDroppedAndTheActiveTabFollows() {
        let kept = sample().keeping { $0 != "/p/main.go" }
        #expect(kept.tabs.map(\.path) == ["/p/with space/a=b.go"] && kept.activePath == "/p/with space/a=b.go")
        let none = sample().keeping { _ in false }
        #expect(none.tabs.isEmpty && none.activePath == nil)
    }

    @Test func caretsAreClampedToWhatIsSensible() {
        let s = SessionState.decode("tab=-5,-2,/p/a.go\n")
        #expect(s.tabs == [SessionTab(path: "/p/a.go", line: 0, character: 0)])
    }

    @Test func aFileSignatureComparesTimeAndSize() {
        let a = FileSignature(modified: 100.0004, size: 10)
        #expect(a == FileSignature(modified: 100.0004, size: 10))
        #expect(a != FileSignature(modified: 101, size: 10))
        #expect(a != FileSignature(modified: 100.0004, size: 11))
    }

    @Test func theDiskStateComesFromTheTwoSignatures() {
        let a = FileSignature(modified: 1, size: 1), b = FileSignature(modified: 2, size: 1)
        #expect(DiskCheck.state(known: a, current: a) == .same)
        #expect(DiskCheck.state(known: a, current: b) == .changed)
        #expect(DiskCheck.state(known: a, current: nil) == .deleted)
        #expect(DiskCheck.state(known: nil, current: nil) == .same)
        #expect(DiskCheck.state(known: nil, current: a) == .changed)
    }

    @Test func whatToDoAboutAChangedFile() {
        #expect(DiskCheck.action(dirty: false, state: .same, notified: false) == .none)
        #expect(DiskCheck.action(dirty: false, state: .changed, notified: false) == .reload)
        #expect(DiskCheck.action(dirty: true, state: .changed, notified: false) == .conflict)
        #expect(DiskCheck.action(dirty: true, state: .changed, notified: true) == .none)
        #expect(DiskCheck.action(dirty: false, state: .deleted, notified: false) == .deleted)
        #expect(DiskCheck.action(dirty: true, state: .deleted, notified: false) == .deleted)
        #expect(DiskCheck.action(dirty: true, state: .deleted, notified: true) == .none)
    }

    @Test func aDirectoryListingChangeIsSeenFromItsSignature() {
        #expect(DiskCheck.state(known: FileSignature(modified: 5, size: 0), current: FileSignature(modified: 6, size: 0)) == .changed)
    }
}
