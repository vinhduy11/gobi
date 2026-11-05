// gobi-bench: measurements for the editor spike. Build with `swift build -c release` for meaningful numbers.
//
//   gobi-bench [--lines N] [--no-highlight] [--no-gutter]        N defaults to 100000
//
// Covers the budgets in the roadmap that the Swift side decides: opening a large file, keystroke cost in a
// TextKit 2 text view, jumping around a large file, decoding large LSP messages, and memory.

import AppKit
import Darwin
import Foundation
import GobiClient
import GobiModel
import GobiEditor

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: helpers

let clock = ContinuousClock()

func milliseconds(_ block: () -> Void) -> Double {
    let started = clock.now
    block()
    let span = clock.now - started
    return Double(span.components.seconds) * 1000 + Double(span.components.attoseconds) / 1e15
}

func residentMegabytes() -> Double {
    var taskMemory = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &taskMemory) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Double(taskMemory.resident_size) / 1_048_576 : 0
}

func percentile(_ samples: [Double], _ fraction: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}

func row(_ name: String, _ measured: String, _ budget: String = "") {
    print(name.padding(toLength: 56, withPad: " ", startingAt: 0) + measured.padding(toLength: 34, withPad: " ", startingAt: 0) + budget)
}

func format(_ milliseconds: Double) -> String { String(format: "%.2f ms", milliseconds) }

let withHighlight = !CommandLine.arguments.contains("--no-highlight")
let withGutter = !CommandLine.arguments.contains("--no-gutter")
var lineCount = 100_000
if let index = CommandLine.arguments.firstIndex(of: "--lines"), index + 1 < CommandLine.arguments.count, let given = Int(CommandLine.arguments[index + 1]) {
    lineCount = given
}

// MARK: sample data

func makeGoSource(lines: Int) -> String {
    var source = "package sample\n\nimport \"context\"\n\n"
    source.reserveCapacity(lines * 90)
    for index in 0 ..< lines {
        switch index % 4 {
        case 0: source += "func handler\(index)(ctx context.Context, request *Request) (*Response, error) {\n"
        case 1: source += "\t// Handler \(index) validates the request and returns a canned response.\n"
        case 2: source += "\treturn &Response{ID: \(index), Message: \"ok\"}, nil\n"
        default: source += "}\n"
        }
    }
    return source
}

func makeCompletionMessage(items: Int) -> Data {
    let entries: [[String: Any]] = (0 ..< items).map { index in
        [
            "label": "SomeExportedIdentifier\(index)", "kind": 3,
            "detail": "func(ctx context.Context, name string) (*Result, error)",
            "documentation": ["kind": "markdown", "value": String(repeating: "documentation text ", count: 8)],
            "textEdit": ["newText": "SomeExportedIdentifier\(index)", "range": ["start": ["line": 10, "character": 4], "end": ["line": 10, "character": 8]]],
        ]
    }
    let message: [String: Any] = ["jsonrpc": "2.0", "id": 42, "result": ["isIncomplete": false, "items": entries]]
    return try! JSONSerialization.data(withJSONObject: message)
}

print("gobi-bench: \(lineCount) lines, \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores")
print("")
row("MEASUREMENT", "RESULT", "BUDGET")

// MARK: protocol side

var sourceText = ""
let buildMs = milliseconds { sourceText = makeGoSource(lines: lineCount) }
let utf16 = Array(sourceText.utf16)
row("generate \(lineCount)-line source (\(utf16.count / 1024) KB)", format(buildMs))

var lineIndex = LineIndex(utf16: utf16)
row("LineIndex build", format(milliseconds { lineIndex = LineIndex(utf16: utf16) }))
var editTimes: [Double] = []
for step in 0 ..< 200 {
    let at = utf16.count / 2 + step
    editTimes.append(milliseconds { lineIndex.replace(range: at ..< at, with: [0x78], before: 0x78, after: 0x78) })
}
row("LineIndex replace (200 edits, median / max)", "\(format(percentile(editTimes, 0.5))) / \(format(editTimes.max()!))")

let completion = makeCompletionMessage(items: 2000)
var framed = frame([UInt8](completion))
row("LSP message size (2000-item completion list)", "\(completion.count / 1024) KB")
row("frame decode of that message, 64 KB chunks", format(milliseconds {
    var decoder = FrameDecoder()
    var offset = 0
    while offset < framed.count {
        let end = min(offset + 65_536, framed.count)
        _ = try? decoder.feed(Array(framed[offset ..< end]))
        offset = end
    }
}))
framed = []

struct CompletionResponse: Decodable {
    struct Outcome: Decodable {
        struct Entry: Decodable { let label: String; let kind: Int }
        let items: [Entry]
    }
    let result: Outcome
}
var serializationTimes: [Double] = [], decoderTimes: [Double] = []
for _ in 0 ..< 15 {
    serializationTimes.append(milliseconds { _ = try? JSONSerialization.jsonObject(with: completion) })
    decoderTimes.append(milliseconds { _ = try? JSONDecoder().decode(CompletionResponse.self, from: completion) })
}
row("decode that message: JSONSerialization (median)", format(percentile(serializationTimes, 0.5)), "completion p95 < 100 ms incl. gopls")
row("decode that message: JSONDecoder, 2 fields (median)", format(percentile(decoderTimes, 0.5)))
row("memory after protocol benchmarks", String(format: "%.0f MB", residentMegabytes()))
print("")

// MARK: tokenizer

var highlightIndex: SyntaxIndex?
let sourceLines = LineIndex(utf16: utf16)
row("syntax: tokenize all \(lineCount) lines", format(milliseconds {
    highlightIndex = SyntaxIndex(language: .go, lineCount: sourceLines.lineCount) { Array(utf16[sourceLines.lineRange($0)]) }
}), "")
var updateTimes: [Double] = []
for _ in 0 ..< 200 {
    updateTimes.append(milliseconds { _ = highlightIndex!.update(firstLine: 50_000, oldLineCount: 1, newLineCount: 1) { Array(utf16[sourceLines.lineRange($0)]) } })
}
row("syntax: re-lex one edited line (median / max)", "\(format(percentile(updateTimes, 0.5))) / \(format(updateTimes.max()!))")
print("")

// MARK: the editor, as the app builds it

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
row("editor setup", "highlight \(withHighlight ? "on" : "off"), gutter \(withGutter ? "on" : "off")")

let memoryBefore = residentMegabytes()
var editor: EditorView!
row("create editor with \(utf16.count / 1024) KB of text (indexes + set text)", format(milliseconds {
    editor = EditorView(fileURL: URL(fileURLWithPath: "/bench/main.go"), text: sourceText, highlight: withHighlight, lineNumbers: withGutter)
}), "open 100k lines < 300 ms")
row("  of which set text on the text view", format(editor.loadMilliseconds))

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = editor.view
window.alphaValue = 0           // laid out and displayed, but invisible
window.ignoresMouseEvents = true
window.orderFrontRegardless()
let textView = editor.textView
let layout = textView.textLayoutManager!

func layOutViewport() {
    textView.layoutSubtreeIfNeeded()
    layout.textViewportLayoutController.layoutViewport()
}
row("first viewport layout", format(milliseconds { layOutViewport() }))
row("first window paint", format(milliseconds { flushPendingPaint() }))
row("scroll to the end, lay out and paint", format(milliseconds {
    textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
    layOutViewport()
    flushPendingPaint()
}))
row("scroll to the middle, lay out and paint", format(milliseconds {
    textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length / 2, length: 0))
    layOutViewport()
    flushPendingPaint()
}))

let middle = (textView.string as NSString).length / 2
textView.setSelectedRange(NSRange(location: middle, length: 0))
var layoutOnly: [Double] = [], withPaint: [Double] = []
for _ in 0 ..< 200 {
    layoutOnly.append(milliseconds {
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
    })
}
for _ in 0 ..< 200 {
    withPaint.append(milliseconds {
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        flushPendingPaint()
    })
}
row("keystroke: edit + indexes + layout (median / p95 / max)", "\(format(percentile(layoutOnly, 0.5))) / \(format(percentile(layoutOnly, 0.95))) / \(format(layoutOnly.max()!))", "keystroke to paint < 16 ms")
row("keystroke: the same plus a window paint (median / p95 / max)", "\(format(percentile(withPaint, 0.5))) / \(format(percentile(withPaint, 0.95))) / \(format(withPaint.max()!))")

var newlines: [Double] = []
for _ in 0 ..< 50 {
    newlines.append(milliseconds {
        textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        flushPendingPaint()
    })
}
row("Return key: newline + layout + paint (median)", format(percentile(newlines, 0.5)))

row("paragraphs coloured / gutter draws", "\(editor.paragraphsColoured) / \(editor.gutterDrawCount)")
let memoryAfter = residentMegabytes()
row("memory with the file loaded", String(format: "%.0f MB (+%.0f MB for the editor)", memoryAfter, memoryAfter - memoryBefore), "idle < 150 MB excluding gopls")
print("")
print("Layout and painting are measured for the visible viewport; the window is invisible but drawn normally.")
exit(0)
