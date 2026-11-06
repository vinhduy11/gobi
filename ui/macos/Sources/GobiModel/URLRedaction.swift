/// Removes the password from `scheme://user:password@host` addresses, in a single address or anywhere in a message.
/// An address without a password, an scp-style `git@host:path` and a path containing `@` stay as they are.
public enum URLRedaction {
    public static func redact(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            out.append(chars[index])
            // After "://", the authority runs to the next "/", "?", "#", quote or space.
            if chars[index] == "/", index >= 1, chars[index - 1] == ":", index + 1 < chars.count, chars[index + 1] == "/" {
                out.append("/")
                index += 2
                var end = index
                while end < chars.count, !"/?# \t\n'\"".contains(chars[end]) { end += 1 }
                let authority = Array(chars[index ..< end])
                if let at = authority.lastIndex(of: "@"), let colon = authority[..<at].firstIndex(of: ":") {
                    out += authority[..<colon] + authority[at...]
                } else {
                    out += authority
                }
                index = end
                continue
            }
            index += 1
        }
        return String(out)
    }
}
