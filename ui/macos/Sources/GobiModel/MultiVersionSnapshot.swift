/// The last "Run on multiple Go versions" result of one project, kept as text between runs. Format: a `v1<TAB>finishedAt` line,
/// then one line per version with tab-separated fields (version, vet, test, time, vet excerpt, test excerpt), where `\`, tab and
/// newline are escaped.
public struct MultiVersionSnapshot: Equatable {
    public let finishedAt: Int
    public let rows: [MultiVersionRow]

    public init(finishedAt: Int, rows: [MultiVersionRow]) {
        self.finishedAt = finishedAt
        self.rows = rows
    }

    public var encoded: String {
        var lines = ["v1\t\(finishedAt)"]
        for row in rows {
            lines.append([row.version, row.vetText, row.testText, row.timeText, row.vetExcerpt, row.testExcerpt].map(Self.escape).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> MultiVersionSnapshot? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let head = lines.first else { return nil }
        let headFields = head.split(separator: "\t", omittingEmptySubsequences: false)
        guard headFields.count == 2, headFields[0] == "v1", let finished = Int(headFields[1]) else { return nil }
        var rows: [MultiVersionRow] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
            guard fields.count == 6 else { return nil }
            rows.append(MultiVersionRow(version: fields[0], vet: fields[1], test: fields[2], time: fields[3], vetExcerpt: fields[4], testExcerpt: fields[5]))
        }
        return MultiVersionSnapshot(finishedAt: finished, rows: rows)
    }

    /// "last run: 5 min ago" from two clock readings in seconds.
    public static func lastRunText(finishedAt: Int, now: Int) -> String {
        let elapsed = now - finishedAt
        if elapsed < 60 { return "last run: just now" }
        if elapsed < 3600 { return "last run: \(elapsed / 60) min ago" }
        if elapsed < 86400 { return "last run: \(elapsed / 3600) h ago" }
        return "last run: \(elapsed / 86400) d ago"
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            default: out.append(character)
            }
        }
        return out
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                out.append(character == "t" ? "\t" : character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}
