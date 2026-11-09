/// Removes `CSI > Pm m` (xterm's modifyOtherKeys reset, sent by Claude Code and other TUIs) from the shell's output.
/// SwiftTerm ignores the `>` and reads it as SGR `Pm m`, so `ESC [ > 4 m` turns underline on for everything after it.
/// A sequence can be cut at a chunk boundary, so the unfinished tail of a chunk is held for the next one.
public struct TerminalOutputFilter {
    private var held: [UInt8] = []

    public init() {}

    public mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        let input = held + bytes
        held = []
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            guard input[i] == 0x1b else { output.append(input[i]); i += 1; continue }
            switch Self.match(input, at: i) {
            case .drop(let length): i += length
            case .keep: output.append(input[i]); i += 1
            case .incomplete: held = Array(input[i...]); return output
            }
        }
        return output
    }

    private enum Match { case drop(Int), keep, incomplete }

    /// ESC [ > (digits or ;)* m
    private static func match(_ s: [UInt8], at start: Int) -> Match {
        let pattern: [UInt8] = [0x1b, UInt8(ascii: "["), UInt8(ascii: ">")]
        var i = start
        for expected in pattern {
            guard i < s.count else { return .incomplete }
            guard s[i] == expected else { return .keep }
            i += 1
        }
        while i < s.count {
            let b = s[i]
            i += 1
            if b == UInt8(ascii: "m") { return .drop(i - start) }
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || b == UInt8(ascii: ";") else { return .keep }
        }
        return .incomplete
    }
}
