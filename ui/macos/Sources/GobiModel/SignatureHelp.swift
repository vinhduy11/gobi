// What gopls' textDocument/signatureHelp answers, reduced to the one line the popup shows and the part of it to make bold.
// Offsets are UTF-16 units.

public struct SignatureText: Equatable {
    public var label: String
    /// The active parameter inside `label`; nil when the answer names none.
    public var activeRange: Range<Int>?

    public var parts: (before: String, active: String, after: String) {
        let units = Array(label.utf16)
        guard let range = activeRange, range.lowerBound >= 0, range.upperBound <= units.count else { return (label, "", "") }
        func text(_ slice: ArraySlice<UInt16>) -> String { String(decoding: slice, as: UTF16.self) }
        return (text(units[..<range.lowerBound]), text(units[range]), text(units[range.upperBound...]))
    }
}

public enum SignatureHelp {
    /// The active signature of a SignatureHelp result, or nil when there is none.
    public static func parse(_ result: Any?) -> SignatureText? {
        guard let answer = result as? [String: Any], let signatures = answer["signatures"] as? [[String: Any]], !signatures.isEmpty else { return nil }
        let chosen = min(max(answer["activeSignature"] as? Int ?? 0, 0), signatures.count - 1)
        let signature = signatures[chosen]
        guard let label = signature["label"] as? String else { return nil }
        let units = Array(label.utf16)
        let active = signature["activeParameter"] as? Int ?? answer["activeParameter"] as? Int ?? 0
        let parameters = signature["parameters"] as? [[String: Any]] ?? []
        guard parameters.indices.contains(active) else { return SignatureText(label: label, activeRange: nil) }
        // Text labels are searched for in order, after the opening parenthesis, so a name that repeats the function's does not match it.
        var cursor = units.firstIndex(of: 40).map { $0 + 1 } ?? 0
        var found: Range<Int>?
        for (position, parameter) in parameters.enumerated() {
            var range: Range<Int>?
            if let offsets = parameter["label"] as? [Int], offsets.count == 2, offsets[0] <= offsets[1] {
                range = offsets[0] ..< offsets[1]
            } else if let text = parameter["label"] as? String, let at = find(Array(text.utf16), in: units, from: cursor) {
                range = at ..< at + text.utf16.count
            }
            if let range { cursor = range.upperBound }
            if position == active { found = range }
        }
        return SignatureText(label: label, activeRange: found)
    }

    private static func find(_ needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var at = start
        while at + needle.count <= haystack.count {
            if haystack[at ..< at + needle.count].elementsEqual(needle) { return at }
            at += 1
        }
        return nil
    }
}
