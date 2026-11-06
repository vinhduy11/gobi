/// The tabs of the bottom panel. A tab is stored and looked up by its id, never by its position, so adding or moving a tab
/// cannot change what a saved session or a call site means.
public enum PanelTab: String, CaseIterable, Sendable {
    case problems, tests, terminal, debug, profiler, diff, output, find

    /// Left to right, as drawn.
    public static let order: [PanelTab] = [.problems, .tests, .terminal, .debug, .profiler, .diff, .output, .find]

    public var title: String {
        switch self {
        case .problems: return "Problems"
        case .tests: return "Tests"
        case .terminal: return "Terminal"
        case .debug: return "Debug"
        case .profiler: return "Profiler"
        case .diff: return "Diff"
        case .output: return "Output"
        case .find: return "Find"
        }
    }

    /// Position in `order`.
    public var index: Int { Self.order.firstIndex(of: self) ?? 0 }

    /// The tab a session saved before ids existed meant by its position. This list is frozen: it is the order of that release.
    private static let legacyOrder: [PanelTab] = [.problems, .tests, .terminal, .debug, .profiler, .diff, .output, .find]

    public init?(legacyIndex: Int) {
        guard Self.legacyOrder.indices.contains(legacyIndex) else { return nil }
        self = Self.legacyOrder[legacyIndex]
    }

    /// Saved text: an id, or the old position as a number. Anything unknown (an id from a newer build) gives Problems.
    public init(stored: String) {
        if let tab = PanelTab(rawValue: stored) { self = tab }
        else if let number = Int(stored), let tab = PanelTab(legacyIndex: number) { self = tab }
        else { self = .problems }
    }
}
