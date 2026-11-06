/// Drops answers that were overtaken: a reply counts only if no newer request was started since and the document is still at the
/// version the request was made for. One gate per kind of request (references, hover...), on the main thread.
public struct RequestGate {
    public struct Ticket: Equatable {
        fileprivate let generation: Int
        fileprivate let version: Int
    }

    private var generation = 0

    public init() {}

    /// Starts a request for the document at `version`; every earlier ticket is void from now on.
    public mutating func begin(version: Int) -> Ticket {
        generation += 1
        return Ticket(generation: generation, version: version)
    }

    /// Voids the request in flight (for example when the file is closed).
    public mutating func cancel() { generation += 1 }

    public func accepts(_ ticket: Ticket, version: Int) -> Bool {
        ticket.generation == generation && ticket.version == version
    }
}
