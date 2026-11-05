// gobi-check: verification harness for the editor (not part of the product). Written by an independent checking pass.
//
//   gobi-check drag FILE [--type-first] [--legacy]     real NSScroller knob drag through the tracking loop
//   gobi-check momentum FILE                           trackpad-style phased scroll events over the whole file
//   gobi-check longline FILE [--width POINTS] [--count N] [--snapshot PNG]          open / keystroke / gutter / highlight on long lines
//   every mode accepts --no-highlight and --no-gutter to switch those features off (to find what costs time)
//   gobi-check find FILE NEEDLE_NEAR_END NEEDLE_MANY   Gobi's find bar: next/previous/wrap against an independent scan
//   windows are invisible and never take focus; add --visible to watch
//   gobi-check ax FILE                                 NSAccessibility surface of the text view and gutter
//   gobi-check paint FILE                              window paint cost with alpha 1 / alpha 0 / ordered out
//   gobi-check highlight FILE [--png-dir DIR]          highlighter and document bookkeeping checks (PNGs of the edits)
//   gobi-check scrollthrough FILE [--stages 1000,5000,20000]   scroll steadily down the file; keystroke cost and memory at each stage
//   gobi-check cliff FILE [--no-fix]                  root-cause experiment for the scroll-jump slowdown and its remedies
//   gobi-check project DIR                             project/new, open, import and clone against a real gobid (writes under DIR)
//   gobi-check fuzz                                    SyntaxIndex/LineIndex fuzz with large multi-line edits

import AppKit
import ApplicationServices
import Darwin
import Foundation
import GobiClient
import GobiEditor

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "help"
let filePath = arguments.count > 2 ? arguments[2] : ""
func hasFlag(_ flag: String) -> Bool { arguments.contains(flag) }
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let clock = ContinuousClock()
func milliseconds(_ block: () -> Void) -> Double {
    let started = clock.now
    block()
    let span = clock.now - started
    return Double(span.components.seconds) * 1000 + Double(span.components.attoseconds) / 1e15
}
func percentile(_ samples: [Double], _ fraction: Double) -> Double {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}
func report(_ label: String, _ samples: [Double]) {
    guard !samples.isEmpty else { print("  \(label): no samples"); return }
    print(String(format: "  %@: median %.2f ms, p95 %.2f ms, max %.2f ms (%d samples)", label, percentile(samples, 0.5), percentile(samples, 0.95), samples.max()!, samples.count))
}
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
}
func residentMegabytes() -> Double {
    var taskMemory = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &taskMemory) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Double(taskMemory.resident_size) / 1_048_576 : 0
}
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Longest gap between 2 ms timer fires over `seconds`: how long the main thread was blocked by deferred work.
func longestStall(seconds: Double) -> Double {
    var last = Date()
    var longest = 0.0
    let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
        let now = Date()
        longest = max(longest, now.timeIntervalSince(last) * 1000)
        last = now
    }
    RunLoop.main.add(timer, forMode: .common)
    spin(seconds)
    timer.invalidate()
    return longest
}

// MARK: fuzz (no window)

func fuzz() {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }
    var failures = 0
    for language in [SyntaxLanguage.go, .json, .markdown] {
        var generator = Seeded(state: 20261105)
        var units = Array("package p\n/* c */\nfunc f() { s := `a\nb` // t\n\treturn \"x\" }\n```\n# h\n{\"k\": [1, true]}\n'x'\n".utf16)
        var index = LineIndex(utf16: units)
        var syntax = SyntaxIndex(language: language, lineCount: index.lineCount) { Array(units[index.lineRange($0)]) }
        let alphabet = Array("/*`\"'\n\n\n\r #-{}:,x1 \\".utf16)
        for step in 0 ..< 3000 {
            let start = Int.random(in: 0 ... units.count, using: &generator)
            let end = Int.random(in: start ... min(units.count, start + (step % 50 == 0 ? 400 : 12)), using: &generator)
            let inserted = (0 ..< Int.random(in: 0 ... 50, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let before = (0 ..< syntax.lineCount).map { syntax.tokens(line: $0) }
            let unitBefore: UInt16? = start > 0 ? units[start - 1] : nil
            let unitAfter: UInt16? = end < units.count ? units[end] : nil
            units.replaceSubrange(start ..< end, with: inserted)
            let change = index.replace(range: start ..< end, with: inserted, before: unitBefore, after: unitAfter)
            let (firstLine, oldLineCount, newLineCount) = (change.firstLine, change.oldLineCount, change.newLineCount)
            let changed = syntax.update(firstLine: firstLine, oldLineCount: oldLineCount, newLineCount: newLineCount) { Array(units[index.lineRange($0)]) }
            let rebuilt = SyntaxIndex(language: language, lineCount: index.lineCount) { Array(units[index.lineRange($0)]) }
            if syntax != rebuilt {
                print("  FAIL \(language) step \(step): index diverged from rebuild")
                failures += 1
                break
            }
            // Every line outside `changed` must carry the tokens it had before (shifted by the line delta).
            let shift = newLineCount - oldLineCount
            for line in 0 ..< syntax.lineCount where !changed.contains(line) {
                let oldLine = line < firstLine ? line : line - shift
                if oldLine < 0 || oldLine >= before.count || before[oldLine] != syntax.tokens(line: line) {
                    print("  FAIL \(language) step \(step): line \(line) changed but is outside the returned range \(changed) (first \(firstLine), old \(oldLineCount), new \(newLineCount))")
                    failures += 1
                    break
                }
            }
            if failures > 0 { break }
        }
        print("  \(language): \(failures == 0 ? "ok" : "FAILED") after fuzzing, \(index.lineCount) lines at the end")
    }
    print(failures == 0 ? "FUZZ PASSED" : "FUZZ FAILED")
}

if mode == "fuzz" { fuzz(); exit(0) }
if mode == "help" || filePath.isEmpty { print("usage: see header"); exit(2) }

/// `gobi-check project DIR`: the project calls against a real gobid, creating folders under DIR.
func projectCheck() {
    var failures = 0
    func check(_ name: String, _ passed: Bool) {
        print(passed ? "  ok   \(name)" : "  FAIL \(name)")
        if !passed { failures += 1 }
    }
    do {
        let client = try ControlClient.connect()
        defer { client.close() }
        for template in ["cli", "library", "http", "empty", "workspace"] {
            let info = try client.newProject(NewProjectRequest(template: template, name: "check-\(template)", location: filePath, goVersion: "1.22"))
            let expected: ProjectKind = template == "workspace" ? .workspace : .module
            check("new \(template) project is a \(expected)", info.kind == expected && FileManager.default.fileExists(atPath: info.root))
            if template == "cli" { check("opening it reports the module path", try client.open(path: info.root).modulePath == "check-cli") }
        }
        check("a name with a slash is refused", (try? client.newProject(NewProjectRequest(template: "cli", name: "../x", location: filePath))) == nil)
        check("creating over an existing project is refused", (try? client.newProject(NewProjectRequest(template: "cli", name: "check-cli", location: filePath))) == nil)
        let legacy = filePath + "/legacy"
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try "package main\n\nfunc main() {}\n".write(toFile: legacy + "/main.go", atomically: true, encoding: .utf8)
        let imported = try client.importFolder(path: legacy)
        check("import adds a module named after the folder", imported.kind == .module && imported.modulePath == "legacy")
        check("an unsafe clone URL is refused", (try? client.clone(url: "ext::sh -c id", location: filePath)) == nil)
    } catch {
        print("  FAIL \(error)")
        failures += 1
    }
    print(failures == 0 ? "PROJECT CHECK PASSED" : "PROJECT CHECK FAILED")
}

if mode == "project" { projectCheck(); exit(0) }

// MARK: the editor in a visible window

let application = NSApplication.shared
// Quiet by default: no Dock icon, no focus change, an invisible window. --visible shows it.
let visible = CommandLine.arguments.contains("--visible")
application.setActivationPolicy(visible ? .regular : .accessory)

let fileURL = URL(fileURLWithPath: filePath)
let fileText = try! String(contentsOf: fileURL, encoding: .utf8)
let memoryBefore = residentMegabytes()
var editor: EditorView!
let openMilliseconds = milliseconds { editor = EditorView(fileURL: fileURL, text: fileText, highlight: !hasFlag("--no-highlight"), lineNumbers: !hasFlag("--no-gutter"), wrapWidth: CGFloat(Double(option("--width") ?? "") ?? Double(EditorView.editorWidth))) }
if hasFlag("--no-fix") { editor.mapsLargeJumpsToLines = false }   // baseline: the stock behaviour
let textView = editor.textView
let layout = textView.textLayoutManager!
let scrollView = editor.scrollView
let clip = scrollView.contentView
let document = editor.document

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.contentView = editor.view
window.title = "gobi-check \(mode)"
window.center()
if !visible { window.alphaValue = 0; window.ignoresMouseEvents = true }
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(textView)
if visible { application.activate(ignoringOtherApps: true) }

func layOutViewport() {
    textView.layoutSubtreeIfNeeded()
    layout.textViewportLayoutController.layoutViewport()
}

/// The self-test's typing benchmark: scroll to `location` (default: the middle), insert characters one by one.
func typing(count: Int, at location: Int? = nil, paint: Bool) -> [Double] {
    let target = location ?? (textView.string as NSString).length / 2
    textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    layOutViewport()
    textView.setSelectedRange(NSRange(location: target, length: 0))
    var samples: [Double] = []
    for _ in 0 ..< count {
        samples.append(milliseconds {
            textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            layOutViewport()
            if paint { flushPendingPaint() }
        })
    }
    return samples
}

func renderingAttributes(atOffset offset: Int) -> [NSAttributedString.Key: Any]? {
    guard let location = layout.location(layout.documentRange.location, offsetBy: offset) else { return nil }
    var found: [NSAttributedString.Key: Any]?
    layout.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        found = attributes
        return false
    }
    return found
}
func colour(atOffset offset: Int) -> NSColor? { renderingAttributes(atOffset: offset)?[.foregroundColor] as? NSColor }
/// The colour of the run that contains `offset`, or nil when no coloured run contains it. (enumerateRenderingAttributes
/// may start at a later run when nothing is stored at `offset`, so `colour(atOffset:)` alone can read a neighbour's colour.)
func colourContaining(_ offset: Int) -> NSColor? {
    guard let location = layout.location(layout.documentRange.location, offsetBy: offset) else { return nil }
    var found: NSColor?
    layout.enumerateRenderingAttributes(from: location, reverse: false) { manager, attributes, runRange in
        let start = manager.offset(from: manager.documentRange.location, to: runRange.location)
        let end = manager.offset(from: manager.documentRange.location, to: runRange.endLocation)
        if start <= offset && offset < end { found = attributes[.foregroundColor] as? NSColor }
        return false
    }
    return found
}
/// Every token of `line` is coloured at its first unit and the unit before it (when no token covers it) is not: catches
/// colours that sit at the wrong offset after an edit.
func coloursLineUp(line: Int) -> (Bool, String) {
    let lineStart = document.lineIndex.lineRange(line).lowerBound
    let tokens = document.syntaxIndex.tokens(line: line)
    var misplaced: [String] = []
    for token in tokens {
        let start = lineStart + Int(token.start)
        if colourContaining(start) == nil { misplaced.append("\(start) uncoloured") }
        let before = Int(token.start) - 1
        if before >= 0, !tokens.contains(where: { Int($0.start) <= before && before < Int($0.start) + Int($0.length) }), colourContaining(lineStart + before) != nil {
            misplaced.append("\(lineStart + before) coloured")
        }
    }
    return (misplaced.isEmpty, misplaced.joined(separator: ", "))
}
func same(_ first: NSColor?, _ second: NSColor?) -> Bool {
    guard let first, let second else { return false }
    return first === second || first == second
}
func fraction(ofY yOffset: CGFloat) -> Double { Double(yOffset / max(1, textView.frame.height - clip.bounds.height)) }

func header() {
    print("gobi-check \(mode) \(fileURL.lastPathComponent): \(document.lineIndex.lineCount) lines, \((textView.string as NSString).length) UTF-16 units")
    print(String(format: "  open: EditorView init %.1f ms (set text %.1f ms)", openMilliseconds, editor.loadMilliseconds))
    print(String(format: "  first viewport layout %.2f ms, first window paint %.2f ms", milliseconds { layOutViewport() }, milliseconds { flushPendingPaint() }))
    print(String(format: "  resident memory %.0f MB (+%.0f MB since before the editor)", residentMegabytes(), residentMegabytes() - memoryBefore))
    let storageUnits = Array(textView.string.utf16)
    check("line index built from the file equals one built from the text storage", LineIndex(utf16: storageUnits) == document.lineIndex, "file \(fileText.utf16.count) units, storage \(storageUnits.count) units, lines \(document.lineIndex.lineCount) vs \(LineIndex(utf16: storageUnits).lineCount)")
}
func footer() { print(String(format: "  resident memory at the end %.0f MB", residentMegabytes())) }

// MARK: A. real scroller drag

func mouseEvent(_ type: NSEvent.EventType, at windowPoint: NSPoint, number: Int) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
}

func dragCheck() {
    let memoryBeforeDrag = residentMegabytes()
    header()
    if hasFlag("--legacy") { scrollView.scrollerStyle = .legacy }
    if hasFlag("--type-first") {
        report("100 keystrokes mid-file BEFORE the drag (layout only)", typing(count: 100, paint: false))
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        layOutViewport()
        flushPendingPaint()
    }
    guard let scroller = scrollView.verticalScroller else { print("  FAIL no vertical scroller"); return }
    scrollView.tile()
    flushPendingPaint()
    let knob = scroller.rect(for: .knob)
    let slot = scroller.rect(for: .knobSlot)
    print("  scroller style \(scroller.scrollerStyle == .legacy ? "legacy" : "overlay"), flipped \(scroller.isFlipped), knob \(knob), slot \(slot), proportion \(scroller.knobProportion), value \(scroller.doubleValue)")
    print("  document height \(Int(textView.frame.height)) pt, clip height \(Int(clip.bounds.height)) pt")

    func knobCenter(fraction: Double) -> NSPoint {
        let travel = slot.height - knob.height
        let yInScroller = scroller.isFlipped
            ? slot.minY + CGFloat(fraction) * travel + knob.height / 2
            : slot.maxY - knob.height / 2 - CGFloat(fraction) * travel
        return scroller.convert(NSPoint(x: knob.midX, y: yInScroller), to: nil)
    }

    // One continuous drag: 0 -> 0.96 in 60 steps, back to 0.30 in 40 steps, one step per 16 ms timer tick.
    let downward: [Double] = (1 ... 60).map { step in 0.96 * Double(step) / 60 }
    let upward: [Double] = (1 ... 40).map { step in 0.96 - 0.66 * Double(step) / 40 }
    var path: [Double] = downward + upward
    var fireTimes: [Date] = []
    var clipYAtFire: [CGFloat] = []
    var eventNumber = 1
    var boundsChanges = 0
    let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in boundsChanges += 1 }
    let timer = Timer(timeInterval: 0.016, repeats: true) { timer in
        fireTimes.append(Date())
        clipYAtFire.append(clip.bounds.origin.y)
        if path.isEmpty {
            timer.invalidate()
            window.postEvent(mouseEvent(.leftMouseUp, at: knobCenter(fraction: 0.30), number: eventNumber), atStart: false)
            return
        }
        let next = path.removeFirst()
        eventNumber += 1
        window.postEvent(mouseEvent(.leftMouseDragged, at: knobCenter(fraction: next), number: eventNumber), atStart: false)
    }
    RunLoop.main.add(timer, forMode: .common)
    let total = milliseconds { scroller.mouseDown(with: mouseEvent(.leftMouseDown, at: knobCenter(fraction: 0), number: 1)) }
    NotificationCenter.default.removeObserver(observer)
    print(String(format: "  drag: mouseDown returned after %.0f ms, %d timer ticks, %d clip bounds changes, clip y now %.0f (%.1f%% of the document), scroller value %.3f", total, fireTimes.count, boundsChanges, clip.bounds.origin.y, fraction(ofY: clip.bounds.origin.y) * 100, scroller.doubleValue))
    check("the drag moved the view", boundsChanges >= 1 && clip.bounds.origin.y > 1000)
    var gaps: [Double] = []
    for index in 1 ..< fireTimes.count {
        let gap = fireTimes[index].timeIntervalSince(fireTimes[index - 1]) * 1000
        gaps.append(gap)
        if gap > 50 { print(String(format: "  slow   step %d: %.0f ms between ticks, view was at %.1f%% -> %.1f%%", index, gap, fraction(ofY: clipYAtFire[index - 1]) * 100, fraction(ofY: clipYAtFire[index]) * 100)) }
    }
    let positionsDuringDrag = Set(clipYAtFire.map { Int($0) }).count
    check("the text followed the thumb during the drag (distinct view positions: \(positionsDuringDrag), jumps applied: \(editor.scrollStatistics.remappedJumps))", positionsDuringDrag >= 5)
    report("time between drag ticks (nominal 16 ms; the excess is the step's layout + paint)", gaps)
    print("  scroll statistics (scroll(to:) calls, remapped jumps, setBoundsOrigin calls): \(editor.scrollStatistics)")
    print(String(format: "  window paint right after the drag: %.2f ms", milliseconds { flushPendingPaint() }))
    let afterDrag = typing(count: 100, paint: false)
    report("100 keystrokes mid-file AFTER the drag (layout only)", afterDrag)
    let freshStart = 5.0   // about 3.5 ms median on a fresh 100k-line file (see docs/architect/ui-macos-spike.md)
    check("keystrokes after the drag stay within 1.5 times a fresh start (7.5 ms median)", percentile(afterDrag, 0.5) <= freshStart * 1.5, String(format: "%.2f ms", percentile(afterDrag, 0.5)))
    check("memory grows by at most 60 MB across the drag", residentMegabytes() - memoryBeforeDrag <= 60, String(format: "%+.0f MB", residentMegabytes() - memoryBeforeDrag))
    report("50 keystrokes mid-file AFTER the drag (layout + paint)", typing(count: 50, paint: true))
    check("keystrokes stay under 16 ms", percentile(typing(count: 20, paint: false), 0.5) < 16)
}

/// The self-test's pixel jumps (clip.scroll(to:)) replayed here, to compare with the real drag in the same harness.
func jumpCheck() {
    header()
    if hasFlag("--type-first") { report("100 keystrokes mid-file BEFORE the jumps (layout only)", typing(count: 100, paint: false)) }
    let totalHeight = textView.frame.height
    var jumps: [Double] = []
    for step in 1 ... 20 {
        let target = Double((step * 37) % 100) / 100
        let elapsed = milliseconds {
            if hasFlag("--by-line") {
                let line = Int(Double(document.lineIndex.lineCount - 1) * target)
                textView.scrollRangeToVisible(NSRange(location: document.lineIndex.lineRange(line).lowerBound, length: 0))
            } else {
                clip.scroll(to: NSPoint(x: 0, y: (totalHeight - clip.bounds.height) * target))
                scrollView.reflectScrolledClipView(clip)
            }
            layOutViewport()
            flushPendingPaint()
        }
        jumps.append(elapsed)
        if elapsed > 100 { print(String(format: "  slow   jump %d to %.0f%% took %.0f ms", step, target * 100, elapsed)) }
    }
    report("20 jumps (layout + window paint)", jumps)
    report("100 keystrokes mid-file AFTER the jumps (layout only)", typing(count: 100, paint: false))
}

/// Evidence for the scroll-jump slowdown: memory and keystroke cost before and after one far pixel jump, and whether
/// the usual remedies bring the keystroke cost back.
func cliffCheck() {
    header()
    if hasFlag("--no-fix") { editor.mapsLargeJumpsToLines = false }
    func memory(_ label: String) { print(String(format: "  memory %@: %.0f MB", label, residentMegabytes())) }
    memory("after open")
    let totalHeight = textView.frame.height   // read before typing, which changes the estimate
    print(String(format: "  height text view %.0f pt, viewport %.0f pt", totalHeight, clip.bounds.height))
    report("30 keystrokes, fresh", typing(count: 30, paint: false))
    memory("after typing")
    print(String(format: "  height text view after typing %.0f pt", textView.frame.height))

    let target = (totalHeight - clip.bounds.height) * 0.96
    let jump = milliseconds {
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        layOutViewport()
    }
    print(String(format: "  jump   one far jump to 96%% by pixel offset took %.0f ms (view now at %.0f%% of the file)", jump, fraction(ofY: clip.bounds.origin.y) * 100))
    memory("after the jump")
    report("30 keystrokes AFTER the jump", typing(count: 30, paint: false))

    let invalidated = milliseconds { layout.invalidateLayout(for: layout.documentRange) }
    layOutViewport()
    print(String(format: "  remedy invalidateLayout(whole document) took %.0f ms", invalidated))
    memory("after invalidateLayout")
    report("30 keystrokes after invalidateLayout", typing(count: 30, paint: false))
}

/// Continuous scrolling lays out every paragraph it passes. This scrolls steadily down the file with pixel scroll events (the
/// form that reaches the scroll view here; events with trackpad phases do not move the view, see `momentum`) and reports, at
/// each stage, the per-step time, the memory and the cost of typing, to see whether lines scrolled past slow later edits.
func topLine() -> Int {
    guard let viewport = layout.textViewportLayoutController.viewportRange else { return 0 }
    return document.lineIndex.position(at: layout.offset(from: layout.documentRange.location, to: viewport.location)).line
}

func scrollThroughCheck() {
    header()
    let stages = (option("--stages") ?? "1000,5000,20000").split(separator: ",").compactMap { Int($0) }
    clip.scroll(to: .zero)
    scrollView.reflectScrolledClipView(clip)
    layOutViewport()
    let fresh = typing(count: 30, at: 0, paint: false)
    report("30 keystrokes at the top, fresh", fresh)
    let freshMedian = percentile(fresh, 0.5)
    var stepTimes: [Double] = []
    var stage = 0
    while stage < stages.count {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else { print("  FAIL cannot make scroll events"); return }
        let before = clip.bounds.origin.y
        // A real scroll event ends a run-loop turn and drains autoreleased objects; a tight loop would not.
        stepTimes.append(autoreleasepool {
            milliseconds {
                scrollView.scrollWheel(with: event)
                layOutViewport()
                flushPendingPaint()
            }
        })
        if clip.bounds.origin.y <= before { print("  FAIL the view stopped moving at line \(topLine())"); return }
        guard topLine() >= stages[stage] else { continue }
        print(String(format: "  stage  line %d reached, memory %.0f MB (+%.0f MB since before the editor)", topLine(), residentMegabytes(), residentMegabytes() - memoryBefore))
        report("  scroll steps since the last stage (\(stepTimes.count) steps)", stepTimes)
        stepTimes = []
        let typed = typing(count: 30, at: document.lineIndex.lineRange(topLine()).lowerBound, paint: false)
        report("  30 keystrokes after scrolling past \(stages[stage]) lines", typed)
        let ratio = percentile(typed, 0.5) / max(freshMedian, 0.01)
        check("typing after \(stages[stage]) lines scrolled stays within 2 times a fresh start", ratio <= 2, String(format: "%.1f times", ratio))
        stage += 1
    }
}

// MARK: B. trackpad momentum scrolling

var wheelUnits = CGScrollEventUnit.pixel
var wheelContinuous: Int64 = 1
var wheelWithPhases = true
var wheelLocate = false
func wheelEvent(delta: Double, phase: Int64, momentum: Int64) -> NSEvent? {
    guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: wheelUnits, wheelCount: 2, wheel1: Int32(-delta.rounded()), wheel2: 0, wheel3: 0) else { return nil }
    cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: wheelContinuous)
    if wheelWithPhases {
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    }
    cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -delta)
    if wheelLocate, let screen = window.screen {
        // CG uses top-left origin global coordinates.
        let inScreen = window.convertToScreen(textView.convert(textView.visibleRect, to: nil))
        cgEvent.location = CGPoint(x: inScreen.midX, y: screen.frame.maxY - inScreen.midY)
    }
    return NSEvent(cgEvent: cgEvent)
}

enum Delivery: String, CaseIterable { case scrollView, textView, sendEvent, post }
var wheelDelivery = Delivery.scrollView
func deliver(_ event: NSEvent) {
    switch wheelDelivery {
    case .scrollView: scrollView.scrollWheel(with: event)
    case .textView: textView.scrollWheel(with: event)
    case .sendEvent: application.sendEvent(event)
    case .post:
        application.postEvent(event, atStart: false)
        spin(0.01)
    }
}

func momentumCheck() {
    header()
    guard let probe = wheelEvent(delta: 40, phase: 2, momentum: 0), let probeMomentum = wheelEvent(delta: 40, phase: 0, momentum: 2) else { print("  FAIL cannot make events"); return }
    print("  probe event: phase \(probe.phase.rawValue) momentum \(probe.momentumPhase.rawValue) precise \(probe.hasPreciseScrollingDeltas) deltaY \(probe.scrollingDeltaY) window \(String(describing: probe.window)); momentum event: phase \(probeMomentum.phase.rawValue) momentum \(probeMomentum.momentumPhase.rawValue) deltaY \(probeMomentum.scrollingDeltaY)")
    check("events carry trackpad phases", probe.phase == .changed && probeMomentum.momentumPhase == .changed && probe.hasPreciseScrollingDeltas)

    // Find a delivery that actually moves the view with phased events.
    var chosen = false
    for locate in [false, true] {
        for delivery in Delivery.allCases where !chosen {
            wheelLocate = locate
            wheelDelivery = delivery
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
            layOutViewport()
            flushPendingPaint()
            for (delta, phase, momentum) in [(0.0, Int64(1), Int64(0)), (40, 2, 0), (40, 2, 0), (0, 4, 0), (40, 0, 1), (40, 0, 2), (0, 0, 3)] {
                if let event = wheelEvent(delta: delta, phase: phase, momentum: momentum) { deliver(event) }
            }
            spin(0.05)
            let moved = clip.bounds.origin.y
            print("  probe delivery \(delivery.rawValue), located \(locate): view y after 7 phased events = \(Int(moved))")
            if moved > 0 { chosen = true }
        }
    }
    if !chosen {
        wheelWithPhases = false
        wheelDelivery = .scrollView
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        for _ in 0 ..< 3 { if let event = wheelEvent(delta: 40, phase: 0, momentum: 0) { deliver(event) } }
        print("  probe: continuous pixel events WITHOUT phase fields, direct to the scroll view: y = \(Int(clip.bounds.origin.y))")
        chosen = clip.bounds.origin.y > 0
    }
    guard chosen else { print("  FAIL no synthetic scroll event form moved the view; momentum test not possible this way"); return }
    print("  using delivery \(wheelDelivery.rawValue), located \(wheelLocate), phases \(wheelWithPhases)")

    clip.scroll(to: .zero)
    scrollView.reflectScrolledClipView(clip)
    layOutViewport()
    flushPendingPaint()
    let bottom = textView.frame.height - clip.bounds.height
    var samples: [Double] = []
    var hitches: [(fraction: Double, ms: Double)] = []
    var gestures = 0
    var scrolledTotal = 0.0
    func feed(_ delta: Double, _ phase: Int64, _ momentum: Int64) {
        guard let event = wheelEvent(delta: delta, phase: phase, momentum: momentum) else { return }
        let before = clip.bounds.origin.y
        let elapsed = milliseconds {
            deliver(event)
            layOutViewport()
            flushPendingPaint()
        }
        scrolledTotal += Double(clip.bounds.origin.y - before)
        samples.append(elapsed)
        if elapsed > 16 { hitches.append((fraction(ofY: before), elapsed)) }
    }
    let started = Date()
    while clip.bounds.origin.y < bottom - 1 && samples.count < 3_000 {
        gestures += 1
        feed(0, 1, 0)                                     // began
        for step in 1 ... 8 { feed(Double(step) * 20, 2, 0) }   // changed, finger moving
        feed(0, 4, 0)                                     // ended, finger lifted
        var momentumDelta = 320.0
        feed(momentumDelta, 0, 1)                         // momentum began
        while momentumDelta > 4 {
            momentumDelta *= 0.96
            feed(momentumDelta, 0, 2)
            if clip.bounds.origin.y >= bottom - 1 { break }
        }
        feed(0, 0, 3)                                     // momentum ended
    }
    print(String(format: "  %d gestures, %d events in %.1f s wall; view at %.1f%% (y %.0f of %.0f), delta sum %.0f pt", gestures, samples.count, Date().timeIntervalSince(started), fraction(ofY: clip.bounds.origin.y) * 100, clip.bounds.origin.y, bottom, scrolledTotal))
    check("reached the end of the document", clip.bounds.origin.y >= bottom - 1)
    report("per scroll event: scrollWheel + layout + paint", samples)
    print("  events over 16 ms: \(hitches.count); over 50 ms: \(hitches.filter { $0.ms > 50 }.count)")
    for hitch in hitches.sorted(by: { $0.ms > $1.ms }).prefix(12) { print(String(format: "  hitch  %.1f ms at %.1f%% of the file", hitch.ms, hitch.fraction * 100)) }
    report("100 keystrokes mid-file AFTER the momentum scroll (layout only)", typing(count: 100, paint: false))
}

// MARK: C. long lines

func longLineCheck() {
    header()
    layOutViewport()
    var longest = 0
    for line in 0 ..< document.lineIndex.lineCount where document.lineIndex.lineRange(line).count > document.lineIndex.lineRange(longest).count { longest = line }
    let longestRange = document.lineIndex.lineRange(longest)
    print("  longest line: \(longest + 1) with \(longestRange.count) units")
    var fragmentsInViewport = 0
    var lineFragmentsInViewport = 0
    var widestFragment: CGFloat = 0
    if let viewport = layout.textViewportLayoutController.viewportRange {
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY > textView.visibleRect.maxY { return false }
            fragmentsInViewport += 1
            lineFragmentsInViewport += fragment.textLineFragments.count
            widestFragment = max(widestFragment, fragment.layoutFragmentFrame.width)
            return true
        }
    }
    print("  viewport: \(fragmentsInViewport) paragraphs, \(lineFragmentsInViewport) visual lines, widest paragraph \(Int(widestFragment)) pt, text view width \(Int(textView.frame.width)), container width \(Int(textView.textContainer?.size.width ?? 0))")
    check("paragraphs wrap inside the \(Int(textView.frame.width)) pt view", widestFragment <= textView.frame.width)
    if document.isReadOnlyByLineLength {
        check("a line over \(EditorDocument.editableLineLimit) units makes the document read-only", !textView.isEditable, "longest line \(longestRange.count) units")
        let lengthBefore = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("typing into a read-only document changes nothing", (textView.string as NSString).length == lengthBefore)
        textView.scrollRangeToVisible(NSRange(location: longestRange.lowerBound, length: 0))
        layOutViewport()
        flushPendingPaint()
        if let path = option("--snapshot") { editor.snapshot(to: URL(fileURLWithPath: path)); print("  image  wrote \(path)") }
        return
    }
    check("a line within the limit keeps the document editable", textView.isEditable, "longest line \(longestRange.count) units")
    let keys = Int(option("--count") ?? "") ?? (longestRange.count > 100_000 ? 3 : 30)
    let endSamples = typing(count: keys, at: longestRange.upperBound, paint: false)
    report("\(keys) keystrokes at the END of the longest line (layout only)", endSamples)
    check("keystrokes at the end of the longest line take under 100 ms (median)", percentile(endSamples, 0.5) < 100, String(format: "%.1f ms", percentile(endSamples, 0.5)))
    check("the document flags a line over its limit", document.hasOverlongLine == (longestRange.count > EditorDocument.overlongLineLimit), "longest line \(longestRange.count) units, limit \(EditorDocument.overlongLineLimit)")
    report("\(keys) keystrokes at the START of the longest line (layout only)", typing(count: keys, at: longestRange.lowerBound, paint: false))
    report("\(keys) keystrokes at the END of the longest line (layout + paint)", typing(count: keys, at: longestRange.upperBound, paint: true))
    report("\(keys) keystrokes mid-file (layout only)", typing(count: keys, paint: false))
    print(String(format: "  resident memory after typing %.0f MB", residentMegabytes()))
    if document.language == "go" {
        // The trailing `// long line N` comment on the first long line is past the wrap: is it coloured like a short line's comment?
        let text = textView.string as NSString
        let longText = text.substring(with: NSRange(location: longestRange.lowerBound, length: longestRange.count)) as NSString
        let commentInLong = longText.range(of: "//")
        let shortLine = (0 ..< document.lineIndex.lineCount).first { line in
            let range = document.lineIndex.lineRange(line)
            return range.count < 100 && (text.substring(with: NSRange(location: range.lowerBound, length: range.count)) as NSString).contains("//")
        }
        if commentInLong.location != NSNotFound, let shortLine {
            let shortRange = document.lineIndex.lineRange(shortLine)
            let shortComment = (text.substring(with: NSRange(location: shortRange.lowerBound, length: shortRange.count)) as NSString).range(of: "//")
            textView.scrollRangeToVisible(NSRange(location: longestRange.lowerBound, length: 0))
            layOutViewport()
            let longColour = colour(atOffset: longestRange.lowerBound + commentInLong.location + 1)
            textView.scrollRangeToVisible(NSRange(location: shortRange.lowerBound, length: 0))
            layOutViewport()
            let shortColour = colour(atOffset: shortRange.lowerBound + shortComment.location + 1)
            check("comment after the wrap on the long line has the comment colour", same(longColour, shortColour), "long \(String(describing: longColour)) short \(String(describing: shortColour))")
            let keywordColour = colour(atOffset: longestRange.lowerBound)   // `var`
            check("`var` at the start of the long line is coloured", keywordColour != nil)
        }
    }
    textView.scrollRangeToVisible(NSRange(location: longestRange.lowerBound, length: 0))
    layOutViewport()
    flushPendingPaint()
    spin(0.2)
    print(String(format: "  gutter draws %d, last draw %.2f ms", editor.gutterDrawCount, editor.gutterLastDrawMilliseconds))
    if let snapshotPath = option("--snapshot") {
        let paint = editor.snapshot(to: URL(fileURLWithPath: snapshotPath))
        print(String(format: "  snapshot %.1f ms -> %@", paint, snapshotPath))
    }
}

// MARK: D. find

func matchIsVisible(_ range: NSRange) -> Bool {
    let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
    guard screenRect.size != .zero else { return false }
    let inView = textView.convert(window.convertFromScreen(screenRect), from: nil)
    return textView.visibleRect.intersects(inView)
}

func findCheck() {
    header()
    let needleNearEnd = arguments.count > 3 ? arguments[3] : "total"
    let needleMany = arguments.count > 4 ? arguments[4] : "func"
    let text = textView.string as NSString
    func occurrences(_ needle: String) -> [NSRange] {
        var found: [NSRange] = []
        var from = 0
        while from < text.length {
            let match = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
            if match.location == NSNotFound { break }
            found.append(match)
            from = match.upperBound
        }
        return found
    }

    func search(_ needle: String, label: String) {
        let expected = occurrences(needle)
        guard let first = expected.first else { print("  FAIL \(label): needle not in file"); return }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        layOutViewport()
        flushPendingPaint()
        let show = milliseconds { editor.showFindBar() }
        editor.setSearchString(needle)
        print(String(format: "  %@: %d matches, first at %d (line %d), showFindBar %.1f ms, bar visible %@", label, expected.count, first.location, document.lineIndex.position(at: first.location).line + 1, show, editor.isFindBarVisible ? "yes" : "no"))
        var times: [Double] = []
        var firstMatch: NSRange?
        times.append(milliseconds { firstMatch = editor.find(forward: true); layOutViewport(); flushPendingPaint() })
        check("\(label): next selects the first occurrence", firstMatch == first && textView.selectedRange() == first)
        check("\(label): the match is on screen", matchIsVisible(textView.selectedRange()))
        // Walk through up to 40 matches and compare each with the independent scan; then one more step must wrap.
        let steps = min(expected.count, 40)
        var allCorrect = true
        for index in 1 ..< max(steps, 1) {
            var got: NSRange?
            times.append(milliseconds { got = editor.find(forward: true); layOutViewport(); flushPendingPaint() })
            if got != expected[index] { allCorrect = false }
        }
        check("\(label): \(steps) next steps follow the independent scan", allCorrect)
        report("\(label): next (find + layout + paint)", times)
        // Wrap: from the last match, next goes to the first; previous from the first goes to the last.
        textView.setSelectedRange(expected[expected.count - 1])
        check("\(label): next after the last match wraps to the first", editor.find(forward: true) == first)
        check("\(label): previous before the first match wraps to the last", editor.find(forward: false) == expected[expected.count - 1])
        if expected.count > 1 {
            textView.setSelectedRange(expected[1])
            check("\(label): previous steps back one match", editor.find(forward: false) == first)
        }
        report("\(label): 50 keystrokes at the match (layout only)", typing(count: 50, at: textView.selectedRange().location, paint: false))
    }
    search(needleNearEnd, label: "near-end needle")
    search(needleMany, label: "many-matches needle")
    report("100 keystrokes mid-file after both finds (layout only)", typing(count: 100, paint: false))
}

// MARK: E. accessibility

func describe(_ element: NSObject & NSAccessibilityProtocol, _ name: String) {
    print("  \(name): class \(type(of: element)), isAccessibilityElement \(element.isAccessibilityElement()), role \(element.accessibilityRole()?.rawValue ?? "nil"), subrole \(element.accessibilitySubrole()?.rawValue ?? "nil"), roleDescription \(element.accessibilityRoleDescription() ?? "nil"), label \(element.accessibilityLabel() ?? "nil"), hidden \(element.isAccessibilityHidden()), children \(element.accessibilityChildren()?.count ?? 0)")
}

func accessibilityCheck() {
    header()
    layOutViewport()
    describe(textView, "text view")
    describe(scrollView, "scroll view")
    describe(editor.view, "editor view (stack)")
    if let gutter = editor.view.subviews.first(where: { !($0 is NSScrollView) }) {
        describe(gutter, "gutter")
        check("gutter is not an accessibility element (silent for VoiceOver)", !gutter.isAccessibilityElement())
        print("  gutter accessibilityValue: \(String(describing: gutter.accessibilityValue())), identifier \(gutter.accessibilityIdentifier())")
    }
    let visibleChildren = (editor.view.accessibilityChildren() ?? []).compactMap { $0 as? NSObject & NSAccessibilityProtocol }
    print("  editor view accessibility children roles: \(visibleChildren.map { $0.accessibilityRole()?.rawValue ?? "?" })")

    var valueLength = 0
    let valueTime = milliseconds { valueLength = (textView.accessibilityValue() as? String)?.utf16.count ?? -1 }
    print(String(format: "  text view accessibilityValue: %d units in %.1f ms", valueLength, valueTime))
    var characters = 0
    let charactersTime = milliseconds { characters = textView.accessibilityNumberOfCharacters() }
    print(String(format: "  accessibilityNumberOfCharacters %d in %.2f ms", characters, charactersTime))
    print("  accessibilitySelectedTextRange \(NSStringFromRange(textView.accessibilitySelectedTextRange())), accessibilitySelectedText \(String(describing: textView.accessibilitySelectedText()))")
    var visible = NSRange()
    let visibleTime = milliseconds { visible = textView.accessibilityVisibleCharacterRange() }
    print(String(format: "  accessibilityVisibleCharacterRange %@ in %.2f ms", NSStringFromRange(visible), visibleTime))
    var caretLine = 0
    let caretTime = milliseconds { caretLine = textView.accessibilityInsertionPointLineNumber() }
    print(String(format: "  accessibilityInsertionPointLineNumber at the top: %d in %.2f ms", caretLine, caretTime))
    check("the caret line question answers in under 5 ms", caretTime < 5, String(format: "%.2f ms", caretTime))
    let length = (textView.string as NSString).length
    let far = document.lineIndex.lineRange(Int(Double(document.lineIndex.lineCount) * 0.95)).lowerBound
    var lineFor = 0
    let lineForTime = milliseconds { lineFor = textView.accessibilityLine(for: far) }
    print(String(format: "  accessibilityLine(for: offset at 95%%) = %d in %.1f ms (line index says %d)", lineFor, lineForTime, document.lineIndex.position(at: far).line))
    check("the line for an index matches LineIndex and takes under 5 ms", lineFor == document.lineIndex.position(at: far).line && lineForTime < 5, String(format: "%.1f ms", lineForTime))
    var rangeFor = NSRange()
    let rangeForTime = milliseconds { rangeFor = textView.accessibilityRange(forLine: max(0, lineFor)) }
    print(String(format: "  accessibilityRange(forLine: %d) = %@ in %.1f ms", lineFor, NSStringFromRange(rangeFor), rangeForTime))
    check("the range for a line matches LineIndex and takes under 5 ms", rangeFor == NSRange(document.lineIndex.lineRange(max(0, lineFor))) && rangeForTime < 5, String(format: "%.1f ms", rangeForTime))
    var stringFor = ""
    let stringForTime = milliseconds { stringFor = textView.accessibilityString(for: NSRange(location: far, length: 40)) ?? "" }
    print(String(format: "  accessibilityString(for: 40 units at 95%%) = %d units in %.2f ms", stringFor.utf16.count, stringForTime))
    var frameFor = NSRect.zero
    let frameForTime = milliseconds { frameFor = textView.accessibilityFrame(for: NSRange(location: far, length: 5)) }
    print(String(format: "  accessibilityFrame(for: 5 units at 95%%) = %@ in %.1f ms", NSStringFromRect(frameFor), frameForTime))
    textView.setSelectedRange(NSRange(location: far, length: 0))
    textView.scrollRangeToVisible(NSRange(location: far, length: 0))
    layOutViewport()
    var caretLineFar = 0
    let caretFarTime = milliseconds { caretLineFar = textView.accessibilityInsertionPointLineNumber() }
    print(String(format: "  accessibilityInsertionPointLineNumber with the caret at 95%%: %d in %.1f ms", caretLineFar, caretFarTime))
    check("the caret line far into the file matches LineIndex and takes under 5 ms", caretLineFar == document.lineIndex.position(at: far).line && caretFarTime < 5, String(format: "%.1f ms", caretFarTime))
    var attributed: NSAttributedString?
    let attributedTime = milliseconds { attributed = textView.accessibilityAttributedString(for: NSRange(location: far, length: 200)) }
    print(String(format: "  accessibilityAttributedString(for: 200 units at 95%%) = %d units in %.1f ms", attributed?.length ?? -1, attributedTime))
    report("50 keystrokes mid-file after the accessibility queries (layout only)", typing(count: 50, paint: false))
    print("  (document length \(length))")

    // Out-of-process view, as VoiceOver sees it.
    let trusted = AXIsProcessTrusted()
    print("  AXIsProcessTrusted: \(trusted)")
    guard trusted else { print("  out-of-process AX tree not inspected: this process lacks Accessibility permission"); return }
    let appElement = AXUIElementCreateApplication(getpid())
    var focused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
    print("  AX focused element status \(status.rawValue)")
    if status == .success, let focusedElement = focused {
        let element = focusedElement as! AXUIElement
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        print("  AX focused attributes: \((names as? [String] ?? []).joined(separator: " "))")
        for attribute in ["AXRole", "AXNumberOfCharacters", "AXVisibleCharacterRange", "AXInsertionPointLineNumber", "AXSelectedTextRange"] {
            var attributeValue: CFTypeRef?
            let elapsed = milliseconds { AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) }
            print(String(format: "  AX %@ = %@ in %.1f ms", attribute, String(describing: attributeValue), elapsed))
        }
    }
    var axWindow: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &axWindow) == .success, let axWindow {
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 5 else { return }
            var role: CFTypeRef?
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &description)
            print("  AX tree \(String(repeating: "  ", count: depth))\(role as? String ?? "?") (\(description as? String ?? "?"))")
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement] ?? []).prefix(8) { walk(child, depth: depth + 1) }
        }
        walk(axWindow as! AXUIElement, depth: 0)
    }
}

// MARK: G. paint cost with an invisible window

func paintCheck() {
    header()
    let gutter = editor.view.subviews.first { !($0 is NSScrollView) }
    print("  layer-backed: content view \(window.contentView?.layer != nil), text view \(textView.layer != nil), gutter \(gutter?.layer != nil), scroll view \(scrollView.layer != nil)")
    func round(_ label: String, flush: Bool = false) {
        let drawsBefore = editor.gutterDrawCount
        var samples: [Double] = []
        let target = (textView.string as NSString).length / 2
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        layOutViewport()
        textView.setSelectedRange(NSRange(location: target, length: 0))
        for _ in 0 ..< 50 {
            samples.append(milliseconds {
                textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                layOutViewport()
                window.displayIfNeeded()
                if flush { CATransaction.flush() }
            })
        }
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        let gutterNeedsDisplayBefore = gutter?.needsDisplay ?? false
        let textNeedsDisplayBefore = textView.needsDisplay
        let paintOnly = milliseconds { window.displayIfNeeded() }
        let gutterNeedsDisplayAfter = gutter?.needsDisplay ?? false
        let textNeedsDisplayAfter = textView.needsDisplay
        let flushTime = milliseconds { CATransaction.flush() }
        report("\(label): keystroke + layout + displayIfNeeded\(flush ? " + CATransaction.flush" : "")", samples)
        print(String(format: "  %@: gutter draws during the 50 keystrokes %d; needsDisplay before/after displayIfNeeded: gutter %@/%@, text %@/%@; displayIfNeeded alone %.2f ms, CATransaction.flush after it %.2f ms, gutter draws now %d; window visible %@, occlusion visible %@", label, editor.gutterDrawCount - drawsBefore, gutterNeedsDisplayBefore ? "yes" : "no", gutterNeedsDisplayAfter ? "yes" : "no", textNeedsDisplayBefore ? "yes" : "no", textNeedsDisplayAfter ? "yes" : "no", paintOnly, flushTime, editor.gutterDrawCount - drawsBefore, window.isVisible ? "yes" : "no", window.occlusionState.contains(.visible) ? "yes" : "no"))
    }
    round("alpha 1, on screen")
    round("alpha 1, on screen, with CATransaction.flush", flush: true)
    window.alphaValue = 0
    spin(0.1)
    round("alpha 0 (what gobi-bench uses)")
    window.alphaValue = visible ? 1 : 0
    window.orderOut(nil)
    spin(0.1)
    round("ordered out")
    window.makeKeyAndOrderFront(nil)
    spin(0.1)
    round("alpha 1 again")
    let bitmap = milliseconds { editor.snapshot(to: nil) }
    print(String(format: "  cacheDisplay to a bitmap (the self-test's CPU paint): %.2f ms", bitmap))
}

// MARK: F. highlighter and document bookkeeping

func rebuiltIndexesMatch(_ label: String) {
    let units = Array(textView.string.utf16)
    let rebuilt = LineIndex(utf16: units)
    let rebuiltSyntax = SyntaxIndex(language: document.syntaxIndex.language, lineCount: rebuilt.lineCount) { Array(units[rebuilt.lineRange($0)]) }
    check("\(label): line index matches a rebuild", rebuilt == document.lineIndex, "lines \(document.lineIndex.lineCount) vs \(rebuilt.lineCount)")
    check("\(label): syntax index matches a rebuild", rebuiltSyntax == document.syntaxIndex)
}

/// Rendering-attribute runs over `range`, as "start+length:colourName".
func runs(over range: Range<Int>, keyword: NSColor?, comment: NSColor?) -> String {
    guard let from = layout.location(layout.documentRange.location, offsetBy: range.lowerBound) else { return "?" }
    var parts: [String] = []
    layout.enumerateRenderingAttributes(from: from, reverse: false) { manager, attributes, runRange in
        let start = manager.offset(from: manager.documentRange.location, to: runRange.location)
        let end = manager.offset(from: manager.documentRange.location, to: runRange.endLocation)
        guard start < range.upperBound else { return false }
        let colourValue = attributes[.foregroundColor] as? NSColor
        let name = colourValue == nil ? "plain" : same(colourValue, keyword) ? "keyword" : same(colourValue, comment) ? "comment" : "other"
        parts.append("\(start)+\(end - start):\(name)\(attributes[.underlineStyle] == nil ? "" : "+underline")")
        return true
    }
    return parts.joined(separator: " ")
}

/// With `--png-dir DIR`, writes what the editor shows now to DIR/NAME.png; `settle` first does what the run loop does
/// between events (flush the Core Animation transaction, spin briefly), so the picture is what the user would see.
func pictureOfEditor(_ name: String, settle: Bool) {
    guard let directory = option("--png-dir") else { return }
    if settle {
        CATransaction.flush()
        spin(0.05)
    }
    editor.snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(settle ? "-settled" : "").png"))
}

func highlightCheck() {
    header()
    layOutViewport()
    let text = textView.string as NSString
    // Reference colour instances from known tokens in sample.go: `package` (keyword) and `/* A block comment` (comment).
    let packageOffset = text.range(of: "package").location
    let blockOffset = text.range(of: "/* A block").location
    let keywordColour = colour(atOffset: packageOffset)
    let commentColour = colour(atOffset: blockOffset)
    print("  reference colours: keyword \(keywordColour == nil ? "missing" : "found") at \(packageOffset), comment \(commentColour == nil ? "missing" : "found") at \(blockOffset), paragraphs coloured \(editor.paragraphsColoured)")
    check("reference colours differ", keywordColour != nil && commentColour != nil && !same(keywordColour, commentColour))

    // (a) Keyword colour right after the keystroke that completes it, on a fresh empty first line.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    var perKey: [String] = []
    for character in ["f", "u", "n", "c"] {
        textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        perKey.append("\(character):\(same(colour(atOffset: 0), keywordColour) ? "keyword" : colour(atOffset: 0) == nil ? "plain" : "other")")
    }
    check("`func` typed letter by letter has the keyword colour right after the last keystroke", same(colour(atOffset: 0), keywordColour), perKey.joined(separator: " "))
    textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
    layOutViewport()
    check("still the keyword colour after a following space", same(colour(atOffset: 0), keywordColour))

    // (b) Opening a block comment on line 1 recolours line 2 (`package sample`) without line 2 being edited.
    let line1 = document.lineIndex.lineRange(1)
    let line2Before = document.lineIndex.lineRange(2)
    print("  before: line 1 runs [\(runs(over: line1, keyword: keywordColour, comment: commentColour))], line 2 runs [\(runs(over: line2Before, keyword: keywordColour, comment: commentColour))], paragraphs coloured \(editor.paragraphsColoured)")
    textView.setSelectedRange(NSRange(location: line1.lowerBound, length: 0))
    textView.insertText("/*", replacementRange: NSRange(location: NSNotFound, length: 0))
    layOutViewport()
    let line1After = document.lineIndex.lineRange(1)
    let line2After = document.lineIndex.lineRange(2)
    print("  tokens: line 1 \(document.syntaxIndex.tokens(line: 1)), line 2 \(document.syntaxIndex.tokens(line: 2))")
    print("  right after `/*` + layoutViewport: line 1 runs [\(runs(over: line1After, keyword: keywordColour, comment: commentColour))], line 2 runs [\(runs(over: line2After, keyword: keywordColour, comment: commentColour))], paragraphs coloured \(editor.paragraphsColoured)")
    let belowImmediately = colour(atOffset: line2After.lowerBound)
    spin(0.1)
    layOutViewport()
    print("  after 100 ms + layoutViewport: line 1 runs [\(runs(over: line1After, keyword: keywordColour, comment: commentColour))], line 2 runs [\(runs(over: line2After, keyword: keywordColour, comment: commentColour))], paragraphs coloured \(editor.paragraphsColoured)")
    let belowAfterRefresh = colour(atOffset: line2After.lowerBound)
    flushPendingPaint()
    CATransaction.flush()
    spin(0.05)
    let belowAfterPaint = colour(atOffset: line2After.lowerBound)
    print("  after a paint: line 2 runs [\(runs(over: line2After, keyword: keywordColour, comment: commentColour))], paragraphs coloured \(editor.paragraphsColoured)")
    check("`/*` itself has the comment colour right after the keystroke", same(colour(atOffset: line1After.lowerBound), commentColour))
    check("line 2 has the comment colour after the async refresh", same(belowAfterRefresh, commentColour), "immediately \(same(belowImmediately, commentColour) ? "comment" : same(belowImmediately, keywordColour) ? "still keyword" : "plain/other"), after refresh \(same(belowAfterRefresh, commentColour) ? "comment" : same(belowAfterRefresh, keywordColour) ? "still keyword" : "plain/other"), after paint \(same(belowAfterPaint, commentColour) ? "comment" : same(belowAfterPaint, keywordColour) ? "still keyword" : "plain/other")")
    pictureOfEditor("b1-open-comment", settle: true)
    textView.insertText("*/", replacementRange: NSRange(location: NSNotFound, length: 0))
    layOutViewport()
    pictureOfEditor("b2-close-comment", settle: false)
    pictureOfEditor("b2-close-comment", settle: true)
    spin(0.1)
    layOutViewport()
    let lineUpAfterClose = coloursLineUp(line: 1)
    check("line 1 colours sit on the tokens after `*/`", lineUpAfterClose.0, lineUpAfterClose.1)
    check("line 2 is back to the keyword colour after `*/`", same(colour(atOffset: document.lineIndex.lineRange(2).lowerBound), keywordColour), "runs [\(runs(over: document.lineIndex.lineRange(2), keyword: keywordColour, comment: commentColour))]")
    rebuiltIndexesMatch("after the comment edits")

    // (c) A diagnostic underline on the keyword at offset 0, applied by the same code the app uses, keeps the keyword colour.
    let underlined = LSPDiagnostic(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 4), severity: 1, message: "undefined", source: nil)
    DiagnosticUnderlines.apply([underlined], to: textView, lineIndex: document.lineIndex)
    check("a diagnostic underline keeps the keyword colour", same(colour(atOffset: 0), keywordColour), "runs [\(runs(over: 0 ..< 5, keyword: keywordColour, comment: commentColour))]")
    check("a diagnostic underline is drawn on the keyword", renderingAttributes(atOffset: 0)?[.underlineStyle] != nil, "attributes \(String(describing: renderingAttributes(atOffset: 0)?.keys.map(\.rawValue)))")
    if let from = layout.location(layout.documentRange.location, offsetBy: 0), let to = layout.location(from, offsetBy: 4), let range = NSTextRange(location: from, end: to) {
        layout.invalidateRenderingAttributes(for: range)
    }
    layOutViewport()
    print("  after invalidateRenderingAttributes + layoutViewport: runs [\(runs(over: 0 ..< 5, keyword: keywordColour, comment: commentColour))]")
    flushPendingPaint()
    CATransaction.flush()
    spin(0.05)
    print("  after a paint: runs [\(runs(over: 0 ..< 5, keyword: keywordColour, comment: commentColour))]")

    // (d) Batched and programmatic edits through the text storage.
    let storage = textView.textStorage!
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: 2, length: 1), with: "AB\nC")
    let later = document.lineIndex.lineRange(min(5, document.lineIndex.lineCount - 1)).lowerBound
    storage.replaceCharacters(in: NSRange(location: later, length: 0), with: "\n\n")
    storage.endEditing()
    rebuiltIndexesMatch("after a batched two-place edit")
    storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3))
    rebuiltIndexesMatch("after an attribute-only edit")
    textView.undoManager?.undo()
    rebuiltIndexesMatch("after undo")
    textView.string = "package x\n\nfunc main() {\n}\n"
    layOutViewport()
    rebuiltIndexesMatch("after replacing the whole text")
    check("the layout manager is still the same object after replacing the text", textView.textLayoutManager === layout)
    check("`func` on line 2 is coloured after replacing the whole text", same(colour(atOffset: 11), keywordColour), "runs [\(runs(over: 0 ..< 25, keyword: keywordColour, comment: commentColour))]")

    // (e) Paragraph separators the line index does not know: U+2028, lone CR, CRLF.
    for (label, sample, funcOffset) in [("U+2028 inside a line", "a\u{2028}b\nfunc c\n", 4), ("lone CR", "a\rb\nfunc c\n", 4), ("CRLF endings", "a := 1\r\nfunc c() {}\r\n", 8), ("LF only (control)", "a := 1\nfunc c() {}\n", 7)] {
        textView.string = sample
        layOutViewport()
        flushPendingPaint()
        CATransaction.flush()
        spin(0.05)
        var fragments: [String] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            let start = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
            let end = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.endLocation)
            fragments.append("\(start)..<\(end)")
            return true
        }
        let lines = (0 ..< document.lineIndex.lineCount).map { "\(document.lineIndex.lineRange($0))" }
        let funcColour = colour(atOffset: funcOffset)
        check("\(label): `func` has the keyword colour", same(funcColour, keywordColour), "paragraphs \(fragments), line index \(lines), tokens line 1 \(document.syntaxIndex.tokens(line: 1)), runs [\(runs(over: 0 ..< sample.utf16.count, keyword: keywordColour, comment: commentColour))]")
    }

    // (f) Typing a character in front of a keyword makes it an identifier: does the old colour go away?
    for (label, prefix) in [("short line", ""), ("wrapped line (3000 chars before the keyword)", String(repeating: "operand + ", count: 300))] {
        textView.string = "\(prefix)var short = 5 // short\n"
        layOutViewport()
        flushPendingPaint()
        CATransaction.flush()
        spin(0.05)
        let varOffset = prefix.utf16.count
        check("\(label): `var` coloured before the edit", same(colour(atOffset: varOffset), keywordColour))
        textView.setSelectedRange(NSRange(location: varOffset, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        let afterLayout = runs(over: varOffset ..< varOffset + 6, keyword: keywordColour, comment: commentColour)
        pictureOfEditor("f-\(prefix.isEmpty ? "short" : "long")-xvar", settle: false)
        pictureOfEditor("f-\(prefix.isEmpty ? "short" : "long")-xvar", settle: true)
        flushPendingPaint()
        CATransaction.flush()
        spin(0.05)
        let afterPaint = runs(over: varOffset ..< varOffset + 6, keyword: keywordColour, comment: commentColour)
        check("\(label): `xvar` is plain after typing `x` in front of `var`", colourContaining(varOffset + 1) == nil, "tokens \(document.syntaxIndex.tokens(line: 0).prefix(3)), runs after layout [\(afterLayout)], after paint [\(afterPaint)]")
        textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        layOutViewport()
        let lineUp = coloursLineUp(line: 0)
        check("\(label): token colours sit on the tokens after the edit", lineUp.0, lineUp.1)
        check("\(label): still plain after a second keystroke", colourContaining(varOffset + 2) == nil, "runs [\(runs(over: varOffset ..< varOffset + 7, keyword: keywordColour, comment: commentColour))]")
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    switch mode {
    case "drag": dragCheck()
    case "jump": jumpCheck()
    case "cliff": cliffCheck()
    case "scrollthrough": scrollThroughCheck()
    case "momentum": momentumCheck()
    case "longline": longLineCheck()
    case "find": findCheck()
    case "ax": accessibilityCheck()
    case "paint": paintCheck()
    case "highlight": highlightCheck()
    default: print("unknown mode \(mode)")
    }
    footer()
    print("DONE \(mode)")
    exit(0)
}
application.run()
