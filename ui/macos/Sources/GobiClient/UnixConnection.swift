import Darwin
import Foundation
import GobiModel

public enum ConnectionError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case closed
    case rejected(String)

    public var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path too long: \(path)"
        case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
        case .closed: return "connection closed"
        case .rejected(let reason): return "gobid refused the connection: \(reason)"
        }
    }
}

/// A connected unix-domain stream socket with blocking reads and writes.
public final class UnixConnection: @unchecked Sendable {
    private var descriptor: Int32
    private let writeLock = NSLock()

    public init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConnectionError.system("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(descriptor)
            throw ConnectionError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ConnectionError.system("connect", code)
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Blocks until some bytes arrive; nil at end of stream.
    public func read(maxLength: Int = 1 << 16) throws -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: maxLength)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, maxLength) }
            if count > 0 { return Array(chunk[0 ..< count]) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            if errno == EBADF { return nil }   // closed locally while a read was blocked
            throw ConnectionError.system("read", errno)
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + sent, bytes.count - sent) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConnectionError.system("write", errno)
            }
            sent += count
        }
    }

    public func close() {
        let toClose = descriptor
        descriptor = -1
        if toClose >= 0 {
            Darwin.shutdown(toClose, SHUT_RDWR)
            Darwin.close(toClose)
        }
    }
}
