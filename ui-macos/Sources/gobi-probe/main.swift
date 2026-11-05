// gobi-probe: headless end-to-end check of the Swift client against a real gobid.
//
//   gobi-probe FILE [--trusted] [--timeout SECONDS] [--quiet SECONDS] [--hover LINE:COL] [--format] [--no-autostart]
//
// Opens FILE through gobid (starting it if needed), waits for diagnostics, and prints them with timings.
// Exit codes: 0 diagnostics received, 2 usage or connection problem, 3 no diagnostics before the timeout.

import Foundation
import GobiClient

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("gobi-probe: \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let found = arguments[index + 1]
    arguments.removeSubrange(index ... index + 1)
    return found
}

let trusted = flag("--trusted")
let autostart = !flag("--no-autostart")
let wantFormat = flag("--format")
let timeout = Double(option("--timeout") ?? "") ?? 20
let quiet = Double(option("--quiet") ?? "") ?? 1.5
let hover = option("--hover")
guard let path = arguments.first else {
    fail("usage: gobi-probe FILE [--trusted] [--timeout S] [--quiet S] [--hover LINE:COL] [--format] [--no-autostart]")
}

let fileURL = URL(fileURLWithPath: path).standardizedFileURL
guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { fail("cannot read \(path)") }

let language: String
switch fileURL.pathExtension.lowercased() {
case "go": language = "go"
case "json": language = "json"
case "md", "markdown": language = "markdown"
default: fail("unsupported file type: .\(fileURL.pathExtension)")
}

func workspaceRoot(for file: URL, language: String) -> String {
    var directory = file.deletingLastPathComponent()
    guard language == "go" else { return directory.path }
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("go.mod").path) { return directory.path }
        directory.deleteLastPathComponent()
    }
    return file.deletingLastPathComponent().path
}
let root = workspaceRoot(for: fileURL, language: language)

let clock = ContinuousClock()
let started = clock.now
func elapsed() -> String { String(format: "%.0f ms", Double((clock.now - started).components.attoseconds) / 1e15 + Double((clock.now - started).components.seconds) * 1000) }

let session: GobiSession
do {
    session = try Gobid.connect(channel: "lsp", workspaceRoot: root, language: language, trusted: trusted, autostart: autostart)
} catch {
    fail("cannot connect to gobid: \(error)")
}
print("connected     \(elapsed())  language=\(language) root=\(root) trusted=\(trusted)")

let client = LSPClient(session: session)
let lock = NSLock()
nonisolated(unsafe) var latest: [LSPDiagnostic]?
nonisolated(unsafe) var firstAt: String?
nonisolated(unsafe) var lastUpdate = Date()
let uri = fileURL.absoluteString
client.onDiagnostics = { receivedURI, diagnostics in
    guard receivedURI == uri else { return }
    lock.lock()
    if firstAt == nil { firstAt = elapsed() }
    latest = diagnostics
    lastUpdate = Date()
    lock.unlock()
}
client.start()

do {
    try client.initialize(rootPath: root)
} catch {
    fail("initialize failed: \(error)")
}
print("initialized   \(elapsed())  syncKind=\(client.syncKind)")
client.didOpen(uri: uri, languageID: language, version: 1, text: text)

let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
    lock.lock()
    let settled = latest != nil && Date().timeIntervalSince(lastUpdate) >= quiet
    lock.unlock()
    if settled { break }
}

lock.lock()
let diagnostics = latest
lock.unlock()
guard let diagnostics else { fail("no diagnostics within \(timeout) s", code: 3) }
print("diagnostics   first at \(firstAt ?? "?"), \(diagnostics.count) total")
for diagnostic in diagnostics {
    let severity = ["", "error", "warning", "info", "hint"][min(max(diagnostic.severity, 0), 4)]
    print("  \(fileURL.lastPathComponent):\(diagnostic.start.line + 1):\(diagnostic.start.character + 1) \(severity): \(diagnostic.message)\(diagnostic.source.map { " [\($0)]" } ?? "")")
}

if let hover {
    let parts = hover.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { fail("--hover wants LINE:COL (0-based)") }
    let answer = try? client.requestAndWait("textDocument/hover", params: [
        "textDocument": ["uri": uri], "position": ["line": parts[0], "character": parts[1]],
    ])
    print("hover         \(answer.map { String(describing: $0).prefix(200) } ?? "none")")
}
if wantFormat {
    let answer = try? client.requestAndWait("textDocument/formatting", params: [
        "textDocument": ["uri": uri], "options": ["tabSize": 2, "insertSpaces": true],
    ])
    print("formatting    \((answer as? [Any])?.count ?? 0) edit(s)")
}
client.close()
exit(0)
