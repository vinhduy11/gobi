/// What gobid found for one tool Gobi uses (core/internal/daemon/control.go, method tools/check).
public struct ToolStatus: Equatable, Sendable {
    public var name: String
    public var required: Bool
    public var found: Bool
    public var version = ""
    public var path = ""
    public var problem = ""
    /// Gobi can fetch it with `go install` after the user agrees.
    public var installable = false
    /// How to get a tool Gobi cannot install itself.
    public var hint = ""

    public init(name: String, required: Bool, found: Bool, version: String = "", path: String = "", problem: String = "", installable: Bool = false, hint: String = "") {
        self.name = name; self.required = required; self.found = found; self.version = version; self.path = path
        self.problem = problem; self.installable = installable; self.hint = hint
    }

    /// The entries (field 1, repeated) of a tools/check result.
    public static func parse(_ fields: [WireField]) -> [ToolStatus] {
        fields.filter { $0.number == 1 }.compactMap { field in
            guard let inner = try? WireField.parse(field.bytes) else { return nil }
            var tool = ToolStatus(name: "", required: false, found: false)
            for item in inner {
                switch item.number {
                case 1: tool.name = item.string
                case 2: tool.required = item.uint != 0
                case 3: tool.found = item.uint != 0
                case 4: tool.version = item.string
                case 5: tool.path = item.string
                case 6: tool.problem = item.string
                case 7: tool.installable = item.uint != 0
                case 8: tool.hint = item.string
                default: break
                }
            }
            return tool.name.isEmpty ? nil : tool
        }
    }

    /// Tools that are not found, required ones first.
    public static func missing(_ tools: [ToolStatus]) -> [ToolStatus] {
        let lost = tools.filter { !$0.found }
        return lost.filter(\.required) + lost.filter { !$0.required }
    }

    /// The setup screen opens by itself only when something required is missing.
    public static func needsAttention(_ tools: [ToolStatus]) -> Bool { tools.contains { $0.required && !$0.found } }

    /// What "Install All Missing" would fetch.
    public static func installable(_ tools: [ToolStatus]) -> [ToolStatus] { missing(tools).filter(\.installable) }
}
