/// Requests waiting for a response, keyed by request id. A timed-out waiter removes its entry with `take`, so a late
/// response finds no handler and nothing is left behind.
public struct PendingReplies<Reply> {
    private var handlers: [Int: (Reply) -> Void] = [:]

    public init() {}

    public var count: Int { handlers.count }

    public mutating func add(_ id: Int, _ handler: @escaping (Reply) -> Void) {
        handlers[id] = handler
    }

    public mutating func take(_ id: Int) -> ((Reply) -> Void)? {
        handlers.removeValue(forKey: id)
    }

    public mutating func takeAll() -> [(Reply) -> Void] {
        let all = Array(handlers.values)
        handlers.removeAll()
        return all
    }
}
