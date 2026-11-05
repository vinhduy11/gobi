import AppKit
import GobiClient
import GobiEditor

/// A window with the editor, a problems list and a status line for one file.
final class EditorWindowController: NSWindowController {
    let editor: EditorView
    var editorFile: EditorDocument { editor.document }
    var textView: NSTextView { editor.textView }
    private let problemsView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private var diagnosticCount: Int?
    private var diagnosticsSeenAt: Date?
    private let createdAt = Date()
    private var connectedAt: Date?
    private var firstDiagnosticsAt: Date?
    private var underlineMilliseconds = 0.0

    init(fileURL: URL, text: String) {
        editor = EditorView(fileURL: fileURL, text: text)
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false))

        let problemsScroll = NSScrollView()
        problemsScroll.hasVerticalScroller = true
        problemsScroll.documentView = problemsView
        problemsView.isEditable = false
        problemsView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        problemsView.textContainerInset = NSSize(width: 6, height: 6)
        problemsScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [editor.view, problemsScroll, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        stack.distribution = .fill
        window?.contentView = stack
        window?.title = fileURL.lastPathComponent
        window?.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: server connection

    /// Connects to gobid on a background thread so the window shows immediately.
    func connect() {
        let editorFile = self.editorFile
        let initialText = textView.string
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try Gobid.connect(channel: "lsp", workspaceRoot: editorFile.workspaceRoot, language: editorFile.language)
                let client = LSPClient(session: session)
                client.onDiagnostics = { uri, diagnostics in
                    guard uri == editorFile.uri else { return }
                    DispatchQueue.main.async { self?.show(diagnostics) }
                }
                client.onNotification = { method, _ in
                    if method == "gobi/lspRestarted" { DispatchQueue.main.async { self?.setStatus("Language server restarted") } }
                }
                client.onDisconnect = { DispatchQueue.main.async { self?.setStatus("Disconnected from gobid") } }
                client.start()
                try client.initialize(rootPath: editorFile.workspaceRoot)
                DispatchQueue.main.async {
                    editorFile.client = client
                    self?.connectedAt = Date()
                    // Anything typed while connecting is covered by sending the current text, not the original.
                    let current = self?.textView.string ?? initialText
                    client.didOpen(uri: editorFile.uri, languageID: editorFile.language, version: editorFile.version, text: current)
                    self?.setStatus("Connected (\(editorFile.language), sync \(client.syncKind == 2 ? "incremental" : "full"))")
                }
            } catch {
                DispatchQueue.main.async { self?.setStatus("Cannot reach gobid: \(error)") }
            }
        }
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text }

    // MARK: diagnostics

    private func show(_ diagnostics: [LSPDiagnostic]) {
        diagnosticCount = diagnostics.count
        diagnosticsSeenAt = Date()
        if firstDiagnosticsAt == nil { firstDiagnosticsAt = Date() }
        let underlineStarted = Date()
        applyUnderlines(diagnostics)
        underlineMilliseconds = Date().timeIntervalSince(underlineStarted) * 1000

        let name = editorFile.fileURL.lastPathComponent
        let lines = diagnostics.map { diagnostic -> String in
            let severity = ["", "error", "warning", "info", "hint"][min(max(diagnostic.severity, 0), 4)]
            return "\(name):\(diagnostic.start.line + 1):\(diagnostic.start.character + 1) \(severity): \(diagnostic.message)"
        }
        problemsView.string = lines.isEmpty ? "No problems" : lines.joined(separator: "\n")
        setStatus("\(diagnostics.count) problem\(diagnostics.count == 1 ? "" : "s")")
    }

    /// Underlines each diagnostic with TextKit 2 rendering attributes, which never touch the text storage.
    private func applyUnderlines(_ diagnostics: [LSPDiagnostic]) {
        guard let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.underlineStyle, for: layout.documentRange)
        layout.removeRenderingAttribute(.underlineColor, for: layout.documentRange)
        let length = (textView.string as NSString).length
        for diagnostic in diagnostics {
            let start = editorFile.lineIndex.offset(of: diagnostic.start)
            var end = editorFile.lineIndex.offset(of: diagnostic.end)
            if end <= start { end = min(start + 1, length) }
            guard end > start,
                  let from = content.location(content.documentRange.location, offsetBy: start),
                  let to = content.location(from, offsetBy: end - start),
                  let range = NSTextRange(location: from, end: to) else { continue }
            let color: NSColor = diagnostic.severity == 1 ? .systemRed : .systemOrange
            layout.setRenderingAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color], for: range)
        }
    }

    // MARK: self test

    /// Waits for the first diagnostics, then checks highlighting, gutter, painting, mouse handling and Vietnamese
    /// composition, printing timings. Used by `--selftest`; `snapshotPath` also writes a PNG of the editor.
    func runSelfTest(timeout: TimeInterval, snapshotPath: String?, finish: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] timer in
            let settled = diagnosticsSeenAt.map { Date().timeIntervalSince($0) > 1.0 } ?? false
            guard settled || Date() > deadline else { return }
            timer.invalidate()

            var passed = true
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
                passed = passed && ok
            }
            func measure(_ label: String, _ samples: [Double]) {
                guard !samples.isEmpty else { return }
                let sorted = samples.sorted()
                print(String(format: "  time   %@: median %.2f ms, p95 %.2f ms, max %.2f ms (%d samples)", label, sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last!, sorted.count))
            }

            print("selftest \(editorFile.fileURL.lastPathComponent) (\(editorFile.lineIndex.lineCount) lines)")
            func since(_ date: Date?) -> String { date.map { String(format: "%.0f ms", $0.timeIntervalSince(createdAt) * 1000) } ?? "never" }
            print(String(format: "  load   text view filled in %.1f ms", editor.loadMilliseconds))
            print("  load   connected to gobid after \(since(connectedAt)), first diagnostics after \(since(firstDiagnosticsAt))")
            print(String(format: "  load   underlining %d diagnostic(s) took %.1f ms", diagnosticCount ?? 0, underlineMilliseconds))

            check("TextKit 2 is active", textView.textLayoutManager != nil)
            check("diagnostics arrived", diagnosticCount != nil, "count=\(diagnosticCount.map(String.init) ?? "none")")

            // Highlighting and gutter: lay out the first screen, look at the attributes, paint to a bitmap.
            layOutViewport()
            let clip = editor.scrollView.contentView
            print(String(format: "  layout clip bounds x=%.1f (view frame x=%.1f, ruler %.0f pt, clip frame x=%.1f, text view width %.0f)", clip.bounds.origin.x, textView.frame.origin.x, editor.scrollView.verticalRulerView?.ruleThickness ?? 0, clip.frame.origin.x, textView.frame.width))
            check("the view starts at the left edge of the text", abs(clip.bounds.origin.x) < 0.5, "x=\(clip.bounds.origin.x)")
            if let gutter = editor.gutterFrame {
                let scrollFrame = editor.scrollView.frame
                check("the text starts to the right of the gutter, not under it", scrollFrame.minX >= gutter.maxX - 0.5, "gutter \(gutter), text area \(scrollFrame)")
            }
            let colouredFirst = firstTokenColoured()
            check("first token is coloured, plain text is not", colouredFirst.token && !colouredFirst.plain, "paragraphs coloured so far: \(editor.paragraphsColoured)")
            let snapshotURL = snapshotPath.map { URL(fileURLWithPath: $0) }
            var paint: [Double] = []
            for attempt in 0 ..< 5 { paint.append(editor.snapshot(to: attempt == 0 ? snapshotURL : nil)) }
            measure("paint the whole editor to a bitmap (CPU)", paint)
            check("gutter drew line numbers", editor.gutterDrawCount > 0, "draws=\(editor.gutterDrawCount), last \(String(format: "%.2f", editor.gutterLastDrawMilliseconds)) ms")
            if let snapshotURL { print("  image  wrote \(snapshotURL.path)") }

            check("mouse handling", mouseChecks())
            let order = ProcessInfo.processInfo.environment["GOBI_SCROLL_FIRST"] != nil
            if order { scrollChecks(measure: measure) }
            measure("100 keystrokes mid-file (layout only)", typingBenchmark(count: 100, paint: false))
            measure("50 keystrokes mid-file (layout + paint window)", typingBenchmark(count: 50, paint: true))
            if !order { scrollChecks(measure: measure) }


            let result = simulateVietnameseTyping()
            check("Vietnamese composition leaves the text correct", result.text, result.detail)
            check("no marked text left after commit", result.committed)
            check("line index still matches the text", result.indexMatches)
            check("syntax index still matches the text", result.syntaxMatches)
            check("edits reached the server (changes sent: \(editorFile.changesSent))", editorFile.changesSent > 0 || editorFile.client == nil)
            finish(passed)
        }
    }

    private func layOutViewport() {
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// Rendering attributes of the run that starts at `location`.
    private func renderingAttributes(at location: NSTextLocation, in layout: NSTextLayoutManager) -> [NSAttributedString.Key: Any]? {
        var found: [NSAttributedString.Key: Any]?
        layout.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
            found = attributes
            return false
        }
        return found
    }

    /// Whether the first token in the file has a colour and a plain position on the same line does not.
    private func firstTokenColoured() -> (token: Bool, plain: Bool) {
        guard let layout = textView.textLayoutManager,
              let start = layout.location(layout.documentRange.location, offsetBy: 0),
              let line = (0 ..< min(editorFile.lineIndex.lineCount, 60)).first(where: { !editorFile.syntaxIndex.tokens(line: $0).isEmpty }),
              let first = editorFile.syntaxIndex.tokens(line: line).first else { return (false, false) }
        let lineStart = editorFile.lineIndex.lineRange(line).lowerBound
        guard let tokenLocation = layout.location(start, offsetBy: lineStart + Int(first.start)) else { return (false, false) }
        let tokenColoured = renderingAttributes(at: tokenLocation, in: layout)?[.foregroundColor] != nil
        let tokens = editorFile.syntaxIndex.tokens(line: line)
        let covered = Set(tokens.flatMap { Int($0.start) ..< Int($0.start + $0.length) })
        let lineLength = editorFile.lineIndex.lineRange(line).count
        guard let plainOffset = (0 ..< lineLength).first(where: { !covered.contains($0) && $0 > Int(first.start) + Int(first.length) }),
              let plainLocation = layout.location(start, offsetBy: lineStart + plainOffset) else { return (tokenColoured, false) }
        return (tokenColoured, renderingAttributes(at: plainLocation, in: layout)?[.foregroundColor] != nil)
    }

    // MARK: mouse

    private func mouseEvent(_ type: NSEvent.EventType, at windowPoint: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// The window point just right of the left edge of the character at `offset`.
    private func windowPoint(forCharacterAt offset: Int) -> NSPoint? {
        guard let window else { return nil }
        // A one-character range: TextKit 2 returns an empty rect for a zero-length one.
        let caret = textView.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
        guard caret.height > 0 else { return nil }
        return window.convertFromScreen(NSRect(x: caret.minX + 1, y: caret.midY, width: 0, height: 0)).origin
    }

    /// Plays a press, optional drags and a release through the text view's own tracking loop; returns milliseconds.
    @discardableResult
    private func mouse(from start: NSPoint, dragging path: [NSPoint] = [], clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> Double {
        guard let window else { return 0 }
        print("  step   mouse press (clickCount \(clickCount), \(path.count) drags, modifiers \(modifiers.rawValue))")
        let started = Date()
        let release = path.last ?? start
        for point in path { window.postEvent(mouseEvent(.leftMouseDragged, at: point, clickCount: clickCount, modifiers: modifiers), atStart: false) }
        window.postEvent(mouseEvent(.leftMouseUp, at: release, clickCount: clickCount, modifiers: modifiers), atStart: false)
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: start, clickCount: clickCount, modifiers: modifiers))
        return Date().timeIntervalSince(started) * 1000
    }

    /// Clicks, double and triple clicks, shift-click and a drag, each verified against the selection it should make.
    private func mouseChecks() -> Bool {
        window?.makeFirstResponder(textView)
        layOutViewport()
        let text = textView.string as NSString
        guard let line = (0 ..< min(editorFile.lineIndex.lineCount, 60)).first(where: { editorFile.lineIndex.lineRange($0).count >= 12 }) else {
            print("  FAIL mouse: no suitable line on screen")
            return false
        }
        let range = editorFile.lineIndex.lineRange(line)
        let lineText = text.substring(with: NSRange(location: range.lowerBound, length: range.count)) as NSString
        let wordStart = range.lowerBound + lineText.rangeOfCharacter(from: .alphanumerics).location
        let inWord = wordStart + 2
        let farther = range.lowerBound + 10
        guard let clickPoint = windowPoint(forCharacterAt: inWord), let fartherPoint = windowPoint(forCharacterAt: farther) else {
            print("  FAIL mouse: cannot locate characters on screen")
            return false
        }

        var allCorrect = true
        func expect(_ name: String, _ actual: NSRange, _ wanted: NSRange, _ elapsed: Double) {
            let ok = NSEqualRanges(actual, wanted)
            print("  \(ok ? "ok  " : "FAIL") mouse: \(name) -> \(NSStringFromRange(actual))\(ok ? "" : " expected \(NSStringFromRange(wanted))") in \(String(format: "%.2f", elapsed)) ms")
            allCorrect = allCorrect && ok
        }

        var elapsed = mouse(from: clickPoint)
        expect("single click", textView.selectedRange(), NSRange(location: inWord, length: 0), elapsed)

        elapsed = mouse(from: clickPoint, clickCount: 2)
        let wordRange = textView.selectionRange(forProposedRange: NSRange(location: inWord, length: 0), granularity: .selectByWord)
        expect("double click selects the word", textView.selectedRange(), wordRange, elapsed)

        elapsed = mouse(from: clickPoint, clickCount: 3)
        expect("triple click selects the line", textView.selectedRange(), text.paragraphRange(for: NSRange(location: inWord, length: 0)), elapsed)

        mouse(from: clickPoint)
        elapsed = mouse(from: fartherPoint, modifiers: .shift)
        expect("shift-click extends the selection", textView.selectedRange(), NSRange(location: inWord, length: farther - inWord), elapsed)

        elapsed = mouse(from: clickPoint, dragging: [fartherPoint])
        expect("drag selects", textView.selectedRange(), NSRange(location: inWord, length: farther - inWord), elapsed)
        return allCorrect
    }

    // MARK: scrolling

    private func scrollChecks(measure: (String, [Double]) -> Void) {
        let clip = editor.scrollView.contentView
        let totalHeight = textView.frame.height
        guard totalHeight > clip.bounds.height * 3 else { return }   // nothing worth scrolling in a small file

        // Wheel: 100 events of three lines each, laying out after each.
        var wheel: [Double] = []
        clip.scroll(to: .zero)
        editor.scrollView.reflectScrolledClipView(clip)
        for _ in 0 ..< 100 {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cgEvent) else { break }
            let started = Date()
            editor.scrollView.scrollWheel(with: event)
            layOutViewport()
            wheel.append(Date().timeIntervalSince(started) * 1000)
        }
        measure("scroll wheel, 100 events (layout)", wheel)
        let moved = clip.bounds.origin.y
        print("  \(moved > 0 ? "ok  " : "FAIL") scroll wheel moved the view to y=\(Int(moved)) of \(Int(totalHeight))")

        // Dragging the scroller knob: jumps to arbitrary positions, laying out and painting each time.
        var jumps: [Double] = []
        for step in 1 ... 20 {
            let fraction = Double((step * 37) % 100) / 100
            let started = Date()
            if ProcessInfo.processInfo.environment["GOBI_JUMP_BY_LINE"] != nil {
                // Jump by text position instead of by pixel position: the line is known, its y is not.
                let line = Int(Double(editorFile.lineIndex.lineCount - 1) * fraction)
                textView.scrollRangeToVisible(NSRange(location: editorFile.lineIndex.lineRange(line).lowerBound, length: 0))
            } else {
                clip.scroll(to: NSPoint(x: 0, y: (totalHeight - clip.bounds.height) * fraction))
                editor.scrollView.reflectScrolledClipView(clip)
            }
            layOutViewport()
            editor.snapshot(to: nil)
            jumps.append(Date().timeIntervalSince(started) * 1000)
            if jumps.last! > 200 { print(String(format: "  slow   jump %d to %.0f%% of the file took %.0f ms", step, fraction * 100, jumps.last!)) }
        }
        measure("scroller jump to a random place + paint, 20 jumps", jumps)
    }

    // MARK: typing

    /// Inserts characters mid-file, each followed by a synchronous viewport layout and optionally a window paint.
    private func typingBenchmark(count: Int, paint: Bool) -> [Double] {
        let middle = (textView.string as NSString).length / 2
        textView.scrollRangeToVisible(NSRange(location: middle, length: 0))
        layOutViewport()
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        var samples: [Double] = []
        for _ in 0 ..< count {
            let started = Date()
            textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            layOutViewport()
            if paint { window?.displayIfNeeded() }
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        return samples
    }

    /// Types "tiếng " the way the built-in Vietnamese Telex input method drives a text view: a growing marked
    /// range for the word being composed, then a commit that replaces it.
    private func simulateVietnameseTyping() -> (text: Bool, committed: Bool, indexMatches: Bool, syntaxMatches: Bool, detail: String) {
        let start = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: 0))
        let nowhere = NSRange(location: NSNotFound, length: 0)
        var composing = ""
        for step in ["t", "ti", "tie", "tiê", "tiế", "tiến", "tiếng"] {
            composing = step
            textView.setMarkedText(step, selectedRange: NSRange(location: step.utf16.count, length: 0), replacementRange: nowhere)
        }
        textView.insertText(composing + " ", replacementRange: nowhere)

        let storage = textView.string as NSString
        let tail = storage.substring(from: start)
        let units = Array(textView.string.utf16)
        let rebuilt = LineIndex(utf16: units)
        let rebuiltSyntax = SyntaxIndex(language: editorFile.syntaxIndex.language, lineCount: rebuilt.lineCount) { Array(units[rebuilt.lineRange($0)]) }
        return (tail == "tiếng ", !textView.hasMarkedText(), rebuilt == editorFile.lineIndex, rebuiltSyntax == editorFile.syntaxIndex, "typed text: \"\(tail)\"")
    }
}
