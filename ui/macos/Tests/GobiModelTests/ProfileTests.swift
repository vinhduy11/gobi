import Testing
@testable import GobiModel

@Suite("Profile data")
struct ProfileTests {
    private func node(_ id: UInt64, _ parent: UInt64, _ name: String, flat: UInt64, cum: UInt64, file: String = "", line: UInt64 = 0) -> [UInt8] {
        var inner = WireWriter()
        inner.uint(1, id); inner.uint(2, parent); inner.string(3, name); inner.uint(4, flat); inner.uint(5, cum); inner.string(6, file); inner.uint(7, line)
        var outer = WireWriter()
        outer.message(5) { $0 = inner }
        return outer.bytes
    }

    private func sampleType(_ type: String, _ unit: String) -> [UInt8] {
        var inner = WireWriter()
        inner.string(1, type); inner.string(2, unit)
        var outer = WireWriter()
        outer.message(1) { $0 = inner }
        return outer.bytes
    }

    private func top(_ name: String, _ flat: UInt64, _ cum: UInt64) -> [UInt8] {
        var inner = WireWriter()
        inner.string(1, name); inner.uint(2, flat); inner.uint(3, cum)
        var outer = WireWriter()
        outer.message(6) { $0 = inner }
        return outer.bytes
    }

    @Test func aReplyIsReadIntoTypesTreeAndTop() throws {
        var bytes = sampleType("samples", "count") + sampleType("cpu", "nanoseconds")
        var head = WireWriter()
        head.uint(2, 1); head.uint(3, 100); head.uint(4, 5_000_000_000)
        bytes += head.bytes
        bytes += node(1, 0, "all", flat: 0, cum: 100) + node(2, 1, "main.main", flat: 10, cum: 100, file: "main.go", line: 14) + node(3, 2, "main.work", flat: 90, cum: 90)
        bytes += top("main.work", 90, 90) + top("main.main", 10, 100)
        let data = try ProfileData.parse(try WireField.parse(bytes))
        #expect(data.sampleTypes == [ProfileSampleType(type: "samples", unit: "count"), ProfileSampleType(type: "cpu", unit: "nanoseconds")])
        #expect(data.index == 1 && data.total == 100 && data.durationNanoseconds == 5_000_000_000)
        #expect(data.nodes.map(\.name) == ["all", "main.main", "main.work"])
        #expect(data.nodes[1].file == "main.go" && data.nodes[1].line == 14 && data.nodes[2].parent == 2)
        #expect(data.top.map(\.name) == ["main.work", "main.main"])
        #expect(data.unit == "nanoseconds")
    }

    @Test func valuesAreShownInTheirUnit() {
        #expect(ProfileFormat.value(5_460_000_000, unit: "nanoseconds") == "5.46 s")
        #expect(ProfileFormat.value(120_000_000, unit: "nanoseconds") == "120 ms")
        #expect(ProfileFormat.value(1_500, unit: "nanoseconds") == "1.5 µs")
        #expect(ProfileFormat.value(569, unit: "count") == "569")
        #expect(ProfileFormat.value(1_258_291, unit: "bytes") == "1.2 MB")
        #expect(ProfileFormat.value(2048, unit: "bytes") == "2.0 kB")
        #expect(ProfileFormat.value(12, unit: "bytes") == "12 B")
        #expect(ProfileFormat.percent(5_460, of: 30_000) == "18.2%")
        #expect(ProfileFormat.percent(1, of: 0) == "0.0%")
    }

    @Test func theFlameLayoutPlacesChildrenSideBySideWithinTheirParent() {
        let nodes = [
            ProfileNode(id: 1, parent: 0, name: "all", flat: 0, cum: 100, file: "", line: 0),
            ProfileNode(id: 2, parent: 1, name: "main", flat: 0, cum: 80, file: "", line: 0),
            ProfileNode(id: 3, parent: 1, name: "gc", flat: 20, cum: 20, file: "", line: 0),
            ProfileNode(id: 4, parent: 2, name: "work", flat: 50, cum: 50, file: "", line: 0),
            ProfileNode(id: 5, parent: 2, name: "log", flat: 30, cum: 30, file: "", line: 0),
        ]
        let rects = FlameLayout.rects(nodes)
        #expect(rects.map(\.id) == [1, 2, 3, 4, 5])
        #expect(rects[0].depth == 0 && rects[0].x == 0 && rects[0].width == 1)
        #expect(rects[1].depth == 1 && rects[1].x == 0 && rects[1].width == 0.8)
        #expect(rects[2].depth == 1 && rects[2].x == 0.8 && abs(rects[2].width - 0.2) < 1e-9)
        #expect(rects[3].depth == 2 && rects[3].x == 0 && rects[3].width == 0.5)
        #expect(abs(rects[4].x - 0.5) < 1e-9 && abs(rects[4].width - 0.3) < 1e-9)
    }

    @Test func callersAndCalleesOfANode() {
        let nodes = [
            ProfileNode(id: 1, parent: 0, name: "all", flat: 0, cum: 100, file: "", line: 0),
            ProfileNode(id: 2, parent: 1, name: "main", flat: 0, cum: 100, file: "", line: 0),
            ProfileNode(id: 3, parent: 2, name: "work", flat: 60, cum: 60, file: "", line: 0),
            ProfileNode(id: 4, parent: 2, name: "log", flat: 40, cum: 40, file: "", line: 0),
        ]
        #expect(ProfileTree.caller(of: 3, in: nodes)?.name == "main")
        #expect(ProfileTree.callees(of: 2, in: nodes).map(\.name) == ["work", "log"])
        #expect(ProfileTree.caller(of: 1, in: nodes) == nil)
    }
}
