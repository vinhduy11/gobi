import Testing
@testable import GobiModel

@Suite("Wire format")
struct WireTests {
    @Test func matchesTheProtobufGoldenVectors() {
        var writer = WireWriter()
        writer.uint(1, 150)
        #expect(writer.bytes == [0x08, 0x96, 0x01])
        writer = WireWriter()
        writer.string(2, "testing")
        #expect(writer.bytes == [0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67])
        writer = WireWriter()
        writer.message(3) { $0.uint(1, 150) }
        #expect(writer.bytes == [0x1a, 0x03, 0x08, 0x96, 0x01])
    }

    @Test func readsBackWhatWasWritten() throws {
        var writer = WireWriter()
        writer.uint(1, 7)
        writer.string(2, "héllo")
        writer.bool(3, true)
        writer.message(4) { $0.string(1, "inner") }
        let fields = try WireField.parse(writer.bytes)
        #expect(fields.map(\.number) == [1, 2, 3, 4])
        #expect(fields[0].uint == 7)
        #expect(String(decoding: fields[1].bytes, as: UTF8.self) == "héllo")
        #expect(fields[2].uint == 1)
        let inner = try WireField.parse(fields[3].bytes)
        #expect(String(decoding: inner[0].bytes, as: UTF8.self) == "inner")
    }

    @Test func refusesDamagedInput() {
        let damaged: [[UInt8]] = [[0x08, 0x96], [0x12, 0x09, 0x61], [0x0d, 1, 2, 3, 4], [0x00, 0x01]]
        for input in damaged {
            #expect(throws: WireError.self) { try WireField.parse(input) }
        }
    }

    @Test func emptyStringsAreLeftOutAndZeroesAreKept() {
        var writer = WireWriter()
        writer.string(1, "")
        writer.uint(2, 0)
        #expect(writer.bytes == [0x10, 0x00])
    }

    // The same vectors as the Go tests (internal/ipc/hello_wire_test.go and internal/daemon/control_test.go).
    @Test func helloMatchesTheGoBytes() {
        let hello = Handshake.encodeHello(clientVersion: "t", channel: "control", workspaceRoot: "", trusted: false, language: nil)
        #expect(hello == [0x08, 0x01, 0x12, 0x01, 0x74, 0x1a, 0x07, 0x63, 0x6f, 0x6e, 0x74, 0x72, 0x6f, 0x6c, 0x28, 0x00])
    }

    @Test func replyIsDecoded() throws {
        #expect(try Handshake.decodeReply([0x08, 0x01, 0x10, 0x01]) == Handshake.Reply(ok: true, error: ""))
        var refusal = WireWriter()
        refusal.bool(1, false)
        refusal.uint(2, 1)
        refusal.string(3, "nope")
        #expect(try Handshake.decodeReply(refusal.bytes) == Handshake.Reply(ok: false, error: "nope"))
    }

    @Test func controlRequestMatchesTheGoBytes() {
        let request = ControlWire.request(id: 1, method: "project/open") { $0.string(1, "/p") }
        #expect(request == [0x08, 0x01, 0x12, 0x0c] + Array("project/open".utf8) + [0x1a, 0x04, 0x0a, 0x02, 0x2f, 0x70])
    }

    @Test func controlReplyGivesTheResultOrTheFailure() throws {
        var result = WireWriter()
        result.string(1, "/root")
        result.string(2, "module")
        result.string(3, "example.com/x")
        var success = WireWriter()
        success.uint(1, 5)
        success.raw(3, result.bytes)
        let ok = try ControlWire.parseReply(success.bytes)
        #expect(ok.id == 5)
        #expect(ok.failure == nil)
        #expect(ok.result.count == 3)

        var failure = WireWriter()
        failure.uint(1, 6)
        failure.string(2, "name has a slash")
        let failed = try ControlWire.parseReply(failure.bytes)
        #expect(failed.failure == "name has a slash")
    }
}
