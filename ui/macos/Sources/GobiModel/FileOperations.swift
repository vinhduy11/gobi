// The rules behind Explorer > Cut, Copy, Paste, Delete, Rename and Move. Paths and names in, paths and text out.

public enum FileOperations {
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    /// `name` when unused, else `name copy.ext`, `name copy 2.ext`, ... (the extension is what follows the last dot; a leading dot is no extension).
    public static func freeName(_ name: String, existing: [String]) -> String {
        if !existing.contains(name) { return name }
        var stem = name, ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[name.startIndex ..< dot])
            ext = String(name[dot...])
        }
        var number = 1
        while true {
            let candidate = stem + " copy" + (number == 1 ? "" : " " + String(number)) + ext
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
    }

    /// True when `path` is below `root` (not `root` itself). Paths with `..` parts are never inside.
    public static func isInside(_ path: String, root: String) -> Bool {
        if path.split(separator: "/").contains("..") { return false }
        var base = root
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return path.count > base.count + 1 && path.hasPrefix(base + "/")
    }

    /// True when `path` is `root` or below it (a folder pasted into itself).
    public static func isSameOrInside(_ path: String, root: String) -> Bool {
        path == root || isInside(path, root: root)
    }

    /// Which of `paths` change when `from` is renamed or moved to `to`: `from` itself and everything below it.
    public static func retarget(from: String, to: String, paths: [String]) -> [Move] {
        paths.compactMap { path in
            if path == from { return Move(from: path, to: to) }
            if path.hasPrefix(from + "/") { return Move(from: path, to: to + String(path.dropFirst(from.count))) }
            return nil
        }
    }

    public static func deleteTitle(names: [String]) -> String {
        names.count == 1 ? "Move \(names[0]) to the Trash?" : "Move \(names.count) items to the Trash?"
    }

    public static func deleteDetail(names: [String], unsaved: Int, openTabs: Int) -> String {
        var text = names.joined(separator: ", ")
        if openTabs > 0 {
            text += "\n\(openTabs) open tab\(openTabs == 1 ? "" : "s") will be closed."
            if unsaved > 0 { text += " \(unsaved) has unsaved changes." }
        }
        return text
    }

    /// How many characters of `name` the Rename sheet preselects: all of a folder's name, a file's name up to its last dot.
    public static func renameSelectionLength(_ name: String, isDirectory: Bool) -> Int {
        if !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex { return name.distance(from: name.startIndex, to: dot) }
        return name.count
    }
}
