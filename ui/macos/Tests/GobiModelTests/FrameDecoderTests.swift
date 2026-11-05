import Testing
@testable import GobiModel

// These tests deliberately avoid `import Foundation`: the Command Line Tools ship Swift Testing without
// its Foundation overlay, so the frame codec works on [UInt8] and stays testable there.

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func framed(_ payload: String) -> [UInt8] {
    bytes("Content-Length: \(payload.utf8.count)\r\n\r\n\(payload)")
}

private func text(_ payloads: [[UInt8]]) -> [String] { payloads.map { String(decoding: $0, as: UTF8.self) } }

@Suite("LSP frame decoder")
struct FrameDecoderTests {
    @Test func decodesASingleMessage() throws {
        var decoder = FrameDecoder()
        #expect(text(try decoder.feed(framed(#"{"jsonrpc":"2.0"}"#))) == [#"{"jsonrpc":"2.0"}"#])
    }

    @Test func decodesBackToBackMessagesInOneFeed() throws {
        var decoder = FrameDecoder()
        #expect(text(try decoder.feed(framed("one") + framed("two"))) == ["one", "two"])
    }

    @Test func decodesWhenBytesArriveOneAtATime() throws {
        var decoder = FrameDecoder()
        var collected: [String] = []
        for byte in framed("hello") + framed("world") {
            collected += text(try decoder.feed([byte]))
        }
        #expect(collected == ["hello", "world"])
    }

    @Test func countsPayloadLengthInBytesNotCharacters() throws {
        var decoder = FrameDecoder()
        #expect(text(try decoder.feed(framed("tiếng Việt 😀"))) == ["tiếng Việt 😀"])
    }

    @Test func acceptsContentType() throws {
        var decoder = FrameDecoder()
        let input = bytes("Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\nhi")
        #expect(text(try decoder.feed(input)) == ["hi"])
    }

    @Test func decodesAnEmptyBody() throws {
        var decoder = FrameDecoder()
        let payloads = try decoder.feed(framed(""))
        #expect(payloads.count == 1 && payloads[0].isEmpty)
    }

    @Test(arguments: [
        "Content-Type: x\r\n\r\nhi",                                          // missing length
        "Content-Length: 2\r\nContent-Length: 2\r\n\r\nhi",                    // duplicate length
        "Content-Length: 2\r\nContent-Type: a\r\nContent-Type: b\r\n\r\nhi",   // duplicate type
        "Content-Length: 12a\r\n\r\nhi",                                       // non numeric
        "Content-Length: -1\r\n\r\n",                                          // negative
        "Content-Length: +2\r\n\r\nhi",                                        // plus sign
        "Content-Length: \r\n\r\n",                                            // empty value
        "Content-Length: 99999999999999999999\r\n\r\n",                        // overflow
        "Content-Length: 2\n\nhi",                                             // bare LF
        "Content-Length 2\r\n\r\nhi",                                          // no colon
        "Content-Length: 2\r\nX-Evil: 1\r\n\r\nhi",                            // unknown header
    ])
    func rejectsMalformedHeaders(input: String) {
        var decoder = FrameDecoder()
        #expect(throws: FrameError.self) { try decoder.feed(bytes(input)) }
    }

    @Test func rejectsPayloadsOverTheLimitBeforeBuffering() {
        var decoder = FrameDecoder(maxPayload: 10)
        #expect(throws: FrameError.tooLarge(11)) { try decoder.feed(bytes("Content-Length: 11\r\n\r\n")) }
    }

    @Test func allowsExactlyTheLimit() throws {
        var decoder = FrameDecoder(maxPayload: 10)
        #expect(try decoder.feed(framed("0123456789")).count == 1)
    }

    @Test func rejectsAnOverlongHeaderLine() {
        var decoder = FrameDecoder()
        let input = bytes("X: " + String(repeating: "a", count: 5000))
        #expect(throws: FrameError.self) { try decoder.feed(input) }
    }

    @Test func keepsAPartialFrameUntilTheRestArrives() throws {
        var decoder = FrameDecoder()
        let whole = framed("partial")
        #expect(try decoder.feed(Array(whole.prefix(whole.count - 3))).isEmpty)
        #expect(text(try decoder.feed(Array(whole.suffix(3)))) == ["partial"])
    }

    @Test func manyFramesInOneBigFeedStayFast() throws {
        var decoder = FrameDecoder()
        var input: [UInt8] = []
        for index in 0..<2000 { input += framed("message-\(index)") }
        let payloads = try decoder.feed(input)
        #expect(payloads.count == 2000 && text([payloads[1999]]) == ["message-1999"])
    }

    @Test func encodesAFrame() {
        #expect(String(decoding: frame(bytes("hello")), as: UTF8.self) == "Content-Length: 5\r\n\r\nhello")
    }
}
