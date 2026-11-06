/// The open tabs of a project window: their order, which one is active and which have unsaved edits.
/// Tabs are identified by file path.
public struct TabStrip: Equatable, Sendable {
    public private(set) var paths: [String] = []
    public private(set) var active: String?
    private var dirty: Set<String> = []

    public init() {}

    public var dirtyPaths: [String] { paths.filter(dirty.contains) }
    public func isDirty(_ path: String) -> Bool { dirty.contains(path) }

    public mutating func open(_ path: String) {
        if !paths.contains(path) { paths.append(path) }
        active = path
    }

    public mutating func select(_ path: String) {
        if paths.contains(path) { active = path }
    }

    public mutating func selectNext() { step(by: 1) }
    public mutating func selectPrevious() { step(by: -1) }

    private mutating func step(by offset: Int) {
        guard !paths.isEmpty else { return }
        let current = active.flatMap { paths.firstIndex(of: $0) } ?? 0
        active = paths[(current + offset + paths.count) % paths.count]
    }

    public mutating func setDirty(_ path: String, _ isDirty: Bool) {
        guard paths.contains(path) else { return }
        if isDirty { dirty.insert(path) } else { dirty.remove(path) }
    }

    /// Renames a tab in place: same position, same active and edited marks.
    public mutating func replace(_ path: String, with new: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        paths[index] = new
        if active == path { active = new }
        if dirty.remove(path) != nil { dirty.insert(new) }
    }

    /// Moves a tab to `index` (clamped); the active tab does not change.
    public mutating func place(_ path: String, at index: Int) {
        guard let from = paths.firstIndex(of: path) else { return }
        paths.remove(at: from)
        paths.insert(path, at: max(0, min(index, paths.count)))
    }

    /// Closing the active tab activates its right neighbour, or the left one when it was the last.
    public mutating func close(_ path: String) {
        guard let index = paths.firstIndex(of: path) else { return }
        paths.remove(at: index)
        dirty.remove(path)
        if active == path { active = paths.isEmpty ? nil : paths[min(index, paths.count - 1)] }
    }
}
