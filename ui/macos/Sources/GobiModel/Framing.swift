// LSP base-protocol framing, with the same rules as the Go side (core/internal/rpc): CRLF-terminated headers,
// Content-Length required and digits only, Content-Type allowed once, anything else refused.
// Works on [UInt8] with no Foundation dependency so it stays easy to test.

public enum FrameError: Error, Equatable {
    case malformedHeader(String)
    case tooLarge(Int)
}

/// Encodes one payload as a frame.
public func frame(_ payload: [UInt8]) -> [UInt8] {
    Array("Content-Length: \(payload.count)\r\n\r\n".utf8) + payload
}

/// Incremental frame decoder: feed it whatever bytes arrive, get back every complete payload.
public struct FrameDecoder {
    private static let maxHeaderLine = 4096
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private var pending: [UInt8] = []
    private let maxPayload: Int

    public init(maxPayload: Int = 256 << 20) {
        self.maxPayload = maxPayload
    }

    public mutating func feed(_ incoming: [UInt8]) throws -> [[UInt8]] {
        pending.append(contentsOf: incoming)
        var payloads: [[UInt8]] = []
        var start = 0
        while let header = try parseHeader(from: start) {
            guard pending.count - header.bodyStart >= header.length else { break }
            payloads.append(Array(pending[header.bodyStart ..< header.bodyStart + header.length]))
            start = header.bodyStart + header.length
        }
        if start > 0 { pending.removeSubrange(0 ..< start) }
        return payloads
    }

    private struct Header {
        var length: Int
        var bodyStart: Int
    }

    /// Parses the header block starting at `start`; nil when it is not complete yet.
    private func parseHeader(from start: Int) throws -> Header? {
        var length: Int?
        var sawType = false
        var cursor = start
        while true {
            guard let newlineIndex = pending[cursor...].firstIndex(of: Self.newline) else {
                if pending.count - cursor > Self.maxHeaderLine {
                    throw FrameError.malformedHeader("header line too long")
                }
                return nil
            }
            guard newlineIndex - cursor <= Self.maxHeaderLine else {
                throw FrameError.malformedHeader("header line too long")
            }
            guard newlineIndex > cursor, pending[newlineIndex - 1] == Self.carriageReturn else {
                throw FrameError.malformedHeader("line not terminated by CRLF")
            }
            let line = pending[cursor ..< newlineIndex - 1]
            cursor = newlineIndex + 1
            if line.isEmpty { break }

            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else {
                throw FrameError.malformedHeader("no colon in header line")
            }
            let name = String(decoding: line[line.startIndex ..< colon], as: UTF8.self).lowercased()
            let headerValue = String(decoding: line[(colon + 1)...], as: UTF8.self).trimmingSpaces()
            switch name {
            case "content-length":
                guard length == nil else { throw FrameError.malformedHeader("duplicate Content-Length") }
                guard !headerValue.isEmpty, headerValue.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let parsed = Int(headerValue) else {
                    throw FrameError.malformedHeader("bad Content-Length \(headerValue)")
                }
                length = parsed
            case "content-type":
                guard !sawType else { throw FrameError.malformedHeader("duplicate Content-Type") }
                sawType = true
            default:
                throw FrameError.malformedHeader("unknown header \(name)")
            }
        }
        guard let length else { throw FrameError.malformedHeader("missing Content-Length") }
        guard length <= maxPayload else { throw FrameError.tooLarge(length) }
        return Header(length: length, bodyStart: cursor)
    }
}

private extension String {
    func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(scalars)
    }
}
