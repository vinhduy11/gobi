// The protobuf wire format, hand-coded for the few small messages the UI and gobid exchange (handshake, project
// requests). It matches core/internal/wire; both sides test the same golden bytes. No Foundation, so it is testable
// on its own.

public enum WireError: Error {
    case truncated
    case badFieldNumber
    case varintTooLong
    case unsupportedWireType(Int)
}

public struct WireWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    private mutating func varint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7f) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    private mutating func tag(_ number: Int, _ wireType: UInt64) { varint(UInt64(number) << 3 | wireType) }

    /// Zero is written too, so a reader can tell 0 from missing.
    public mutating func uint(_ number: Int, _ value: UInt64) {
        tag(number, 0)
        varint(value)
    }

    public mutating func bool(_ number: Int, _ value: Bool) { uint(number, value ? 1 : 0) }

    public mutating func raw(_ number: Int, _ value: [UInt8]) {
        tag(number, 2)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    /// An empty string is left out; the reader's default is empty.
    public mutating func string(_ number: Int, _ value: String) {
        if !value.isEmpty { raw(number, Array(value.utf8)) }
    }

    public mutating func message(_ number: Int, _ build: (inout WireWriter) -> Void) {
        var inner = WireWriter()
        build(&inner)
        raw(number, inner.bytes)
    }
}

public struct WireField: Equatable {
    public var number: Int
    public var uint: UInt64
    public var bytes: [UInt8]
    public var isBytes: Bool

    public var string: String { String(decoding: bytes, as: UTF8.self) }

    public static func parse(_ data: [UInt8]) throws -> [WireField] {
        var fields: [WireField] = []
        var index = 0
        while index < data.count {
            let key = try readVarint(data, &index)
            let number = Int(key >> 3)
            guard number != 0, key >> 3 <= 1 << 28 else { throw WireError.badFieldNumber }
            switch key & 7 {
            case 0:
                fields.append(WireField(number: number, uint: try readVarint(data, &index), bytes: [], isBytes: false))
            case 2:
                let length = try readVarint(data, &index)
                guard length <= UInt64(data.count - index) else { throw WireError.truncated }
                fields.append(WireField(number: number, uint: 0, bytes: Array(data[index ..< index + Int(length)]), isBytes: true))
                index += Int(length)
            default:
                throw WireError.unsupportedWireType(Int(key & 7))
            }
        }
        return fields
    }

    private static func readVarint(_ data: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for position in 0 ..< 10 {
            guard index < data.count else { throw WireError.truncated }
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << UInt64(7 * position)
            if byte < 0x80 { return value }
        }
        throw WireError.varintTooLong
    }
}

/// The handshake messages (core/internal/ipc/hello_wire.go): hello 1 protocol, 2 client version, 3 channel,
/// 4 workspace root, 5 trusted, 6 language; reply 1 ok, 2 protocol, 3 error.
public enum Handshake {
    public static let protocolVersion: UInt64 = 1

    public static func encodeHello(clientVersion: String, channel: String, workspaceRoot: String, trusted: Bool, language: String?) -> [UInt8] {
        var writer = WireWriter()
        writer.uint(1, protocolVersion)
        writer.string(2, clientVersion)
        writer.string(3, channel)
        writer.string(4, workspaceRoot)
        writer.bool(5, trusted)
        writer.string(6, language ?? "")
        return writer.bytes
    }

    public struct Reply: Equatable {
        public var ok: Bool
        public var error: String
    }

    public static func decodeReply(_ data: [UInt8]) throws -> Reply {
        var reply = Reply(ok: false, error: "")
        for field in try WireField.parse(data) {
            switch field.number {
            case 1: reply.ok = field.uint != 0
            case 3: reply.error = field.string
            default: break
            }
        }
        return reply
    }
}

/// The control channel messages (core/internal/daemon/control.go).
public enum ControlWire {
    public static func request(id: UInt64, method: String, params: (inout WireWriter) -> Void) -> [UInt8] {
        var writer = WireWriter()
        writer.uint(1, id)
        writer.string(2, method)
        writer.message(3, params)
        return writer.bytes
    }

    public struct Reply {
        public var id: UInt64
        public var failure: String?
        public var result: [WireField]
    }

    public static func parseReply(_ data: [UInt8]) throws -> Reply {
        var reply = Reply(id: 0, failure: nil, result: [])
        for field in try WireField.parse(data) {
            switch field.number {
            case 1: reply.id = field.uint
            case 2: reply.failure = field.string
            case 3: reply.result = try WireField.parse(field.bytes)
            default: break
            }
        }
        return reply
    }
}

/// The terminal channel messages (core/internal/daemon/terminal.go): to the server 1 kind (1 input, 2 resize), 2 data,
/// 3 columns, 4 rows; from the server 1 kind (1 output, 3 exit), 2 data, 5 exit code.
public enum TerminalWire {
    public enum Event: Equatable {
        case output([UInt8])
        case exit(code: Int, message: String)
        case ignored
    }

    public static func input(_ bytes: [UInt8]) -> [UInt8] {
        var writer = WireWriter()
        writer.uint(1, 1)
        writer.raw(2, bytes)
        return writer.bytes
    }

    public static func resize(columns: Int, rows: Int) -> [UInt8] {
        var writer = WireWriter()
        writer.uint(1, 2)
        writer.uint(3, UInt64(max(columns, 1)))
        writer.uint(4, UInt64(max(rows, 1)))
        return writer.bytes
    }

    public static func parse(_ payload: [UInt8]) throws -> Event {
        var kind: UInt64 = 0, code: UInt64 = 0
        var data: [UInt8] = []
        for field in try WireField.parse(payload) {
            switch field.number {
            case 1: kind = field.uint
            case 2: data = field.bytes
            case 5: code = field.uint
            default: break
            }
        }
        switch kind {
        case 1: return .output(data)
        case 3: return .exit(code: Int(code), message: String(decoding: data, as: UTF8.self))
        default: return .ignored
        }
    }
}
