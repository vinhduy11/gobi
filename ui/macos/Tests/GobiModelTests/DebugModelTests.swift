import Testing
@testable import GobiModel

@Suite("Debug model")
struct DebugModelTests {
    @Test func togglingAddsThenRemovesABreakpoint() {
        var b = Breakpoints()
        #expect(b.toggle(path: "/p/main.go", line: 6) == true)
        #expect(b.toggle(path: "/p/main.go", line: 13) == true)
        #expect(b.lines(in: "/p/main.go") == [6, 13])
        #expect(b.toggle(path: "/p/main.go", line: 6) == false)
        #expect(b.lines(in: "/p/main.go") == [13])
        #expect(b.lines(in: "/other.go").isEmpty)
        #expect(b.count == 1)
    }

    @Test func breakpointsRoundTripThroughText() {
        var b = Breakpoints()
        b.toggle(path: "/p/a.go", line: 3)
        b.toggle(path: "/p/a.go", line: 9)
        b.toggle(path: "/p/b dir/b.go", line: 1)
        #expect(Breakpoints.decode(b.encoded()) == b)
        #expect(Breakpoints.decode("junk\n=3\nx=notanumber") == Breakpoints())
    }

    @Test func removingAFileClearsItsBreakpoints() {
        var b = Breakpoints()
        b.toggle(path: "/p/a.go", line: 3)
        b.removeAll(in: "/p/a.go")
        #expect(b.count == 0 && b.paths.isEmpty)
    }

    @Test func frameLabelsMatchTheMock() {
        let frame = DebugFrame(id: 1, name: "example.com/hello/internal/server.(*Server).Run", path: "/w/internal/server/server.go", line: 28)
        #expect(frame.title == "(*Server).Run")
        #expect(frame.location == "server.go:28")
        let plain = DebugFrame(id: 2, name: "main.main", path: "/w/main.go", line: 14)
        #expect(plain.title == "main.main")
        let runtime = DebugFrame(id: 3, name: "runtime.main", path: "/usr/local/go/src/runtime/proc.go", line: 285)
        #expect(runtime.title == "runtime.main" && runtime.location == "proc.go:285")
    }

    @Test func statusTextFollowsTheState() {
        #expect(DebugState.idle.statusText(project: "hello") == "")
        #expect(DebugState.starting.statusText(project: "hello") == "Starting the debugger…")
        #expect(DebugState.running.statusText(project: "hello") == "Debugging hello")
        let stopped = DebugState.stopped(reason: "breakpoint", location: "server.go:28")
        #expect(stopped.statusText(project: "hello") == "Paused at breakpoint · server.go:28")
        #expect(DebugState.ended("exit 0").statusText(project: "hello") == "Finished · exit 0")
    }

    @Test func stepButtonsAreOnlyAvailableWhenPaused() {
        #expect(!DebugState.running.canStep && !DebugState.idle.canStep)
        #expect(DebugState.stopped(reason: "step", location: "a.go:1").canStep)
        #expect(DebugState.running.canPause)
        #expect(DebugState.running.isActive && DebugState.starting.isActive && !DebugState.idle.isActive && !DebugState.ended("x").isActive)
    }
}
