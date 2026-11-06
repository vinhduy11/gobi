/// An unsaved buffer kept aside when a project window closes or the app quits: the text and the file's signature on disk at that time.
public struct RecoveryRecord: Equatable, Sendable {
    public let path: String
    public let signature: FileSignature?
    public let text: String
    public init(path: String, signature: FileSignature?, text: String) { self.path = path; self.signature = signature; self.text = text }

    private static let header = "gobi-recovery 1"

    /// Three header lines (format, signature, path), then the text exactly as it was.
    public func encoded() -> String {
        let sig = signature.map { "\($0.modified),\($0.size),\($0.identity),\($0.digest.map { String($0, radix: 16) } ?? "none")" } ?? "none"
        return Self.header + "\nsig=" + sig + "\npath=" + path + "\n" + text
    }

    public static func decode(_ content: String) -> RecoveryRecord? {
        var rest = Substring(content)
        func line() -> Substring? {
            guard let newline = rest.firstIndex(of: "\n") else { return nil }
            defer { rest = rest[rest.index(after: newline)...] }
            return rest[rest.startIndex ..< newline]
        }
        guard line() == Substring(header), let sigLine = line(), sigLine.hasPrefix("sig="), let pathLine = line(), pathLine.hasPrefix("path=") else { return nil }
        var signature: FileSignature?
        let sig = sigLine.dropFirst(4)
        if sig != "none" {
            let parts = sig.split(separator: ",", omittingEmptySubsequences: false)
            // Records written before the identity and digest existed have two fields.
            guard parts.count == 2 || parts.count == 4, let modified = Double(parts[0]), let size = Int(parts[1]) else { return nil }
            var identity: UInt64 = 0, digest: UInt64?
            if parts.count == 4 {
                guard let parsedIdentity = UInt64(parts[2]) else { return nil }
                identity = parsedIdentity
                if parts[3] != "none" { guard let parsedDigest = UInt64(parts[3], radix: 16) else { return nil }; digest = parsedDigest }
            }
            signature = FileSignature(modified: modified, size: size, identity: identity, digest: digest)
        }
        return RecoveryRecord(path: String(pathLine.dropFirst(5)), signature: signature, text: String(rest))
    }
}

public enum RecoveryAction: Equatable, Sendable {
    /// The file is gone: nothing to restore into.
    case drop
    /// The file is as it was: offer Keep / Discard.
    case restore
    /// The file changed on disk since: offer Keep Mine / Reload from Disk.
    case restoreChanged
}

public enum Recovery {
    public static func action(saved: FileSignature?, disk: FileSignature?, diskDigest: (() -> UInt64?)? = nil) -> RecoveryAction {
        guard let disk else { return .drop }
        return DiskCheck.state(known: saved, current: disk, digest: diskDigest) == .same ? .restore : .restoreChanged
    }

    /// Files whose unsaved text must not be copied into the recovery store: they look like secrets.
    public static func isSensitive(_ path: String) -> Bool {
        let name = String(path.split(separator: "/").last ?? "").lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasPrefix("id_rsa") || name.hasPrefix("credentials") { return true }
        return [".pem", ".key", ".p12"].contains { name.hasSuffix($0) }
    }

    /// A kept buffer is dropped when its file is gone or it is older than 30 days.
    public static func shouldPrune(ageDays: Int, fileExists: Bool) -> Bool { !fileExists || ageDays > 30 }

    /// A short stable name (FNV-1a, 16 hex digits) for a project or file path, usable as a file name.
    public static func key(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
