import Foundation

public struct ProjectInfo: Equatable, Sendable {
    public var root: String
    public var kind: ProjectKind
    public var modulePath: String
}

public struct NewProjectRequest: Sendable {
    public var template: String
    public var name: String
    public var location: String
    public var modulePath: String
    public var goVersion: String
    public var gitInit: Bool

    public init(template: String, name: String, location: String, modulePath: String = "", goVersion: String = "", gitInit: Bool = true) {
        self.template = template
        self.name = name
        self.location = location
        self.modulePath = modulePath
        self.goVersion = goVersion
        self.gitInit = gitInit
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case server(String)
    case badReply

    public var description: String {
        switch self {
        case .server(let message): return message
        case .badReply: return "unexpected reply from gobid"
        }
    }
}

/// Project requests to gobid over the control channel. Calls block, so run them off the main thread.
public final class ControlClient: @unchecked Sendable {
    private let session: GobiSession
    private var nextID: UInt64 = 1

    public init(session: GobiSession) { self.session = session }

    public static func connect() throws -> ControlClient {
        ControlClient(session: try Gobid.connect(channel: "control", workspaceRoot: ""))
    }

    public func close() { session.close() }

    public func newProject(_ request: NewProjectRequest) throws -> ProjectInfo {
        try call("project/new") {
            $0.string(1, request.template)
            $0.string(2, request.name)
            $0.string(3, request.location)
            $0.string(4, request.modulePath)
            $0.string(5, request.goVersion)
            $0.bool(6, request.gitInit)
        }
    }

    public func clone(url: String, location: String, name: String = "") throws -> ProjectInfo {
        try call("project/clone") {
            $0.string(1, url)
            $0.string(2, location)
            $0.string(3, name)
        }
    }

    public func importFolder(path: String, modulePath: String = "") throws -> ProjectInfo {
        try call("project/import") {
            $0.string(1, path)
            $0.string(2, modulePath)
        }
    }

    public func open(path: String) throws -> ProjectInfo {
        try call("project/open") { $0.string(1, path) }
    }

    private func call(_ method: String, _ params: (inout WireWriter) -> Void) throws -> ProjectInfo {
        let id = nextID
        nextID += 1
        try session.send(ControlWire.request(id: id, method: method, params: params))
        guard let payload = try session.nextMessage() else { throw ControlError.badReply }
        let reply = try ControlWire.parseReply(payload)
        if let failure = reply.failure { throw ControlError.server(failure) }
        guard reply.id == id else { throw ControlError.badReply }
        var root = "", kind = "", modulePath = ""
        for field in reply.result {
            switch field.number {
            case 1: root = field.string
            case 2: kind = field.string
            case 3: modulePath = field.string
            default: break
            }
        }
        guard !root.isEmpty, let projectKind = ProjectKind(rawValue: kind) else { throw ControlError.badReply }
        return ProjectInfo(root: root, kind: projectKind, modulePath: modulePath)
    }
}
