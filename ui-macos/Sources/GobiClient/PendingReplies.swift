/// Requests waiting for a response, keyed by request id. A timed-out waiter removes its entry with `take`, so a late
/// response finds no handler and nothing is left behind.
struct PendingReplies<Reply> {
    private var handlers: [Int: (Reply) -> Void] = [:]

    var count: Int { handlers.count }

    mutating func add(_ id: Int, _ handler: @escaping (Reply) -> Void) {
        handlers[id] = handler
    }

    mutating func take(_ id: Int) -> ((Reply) -> Void)? {
        handlers.removeValue(forKey: id)
    }

    mutating func takeAll() -> [(Reply) -> Void] {
        let all = Array(handlers.values)
        handlers.removeAll()
        return all
    }
}
