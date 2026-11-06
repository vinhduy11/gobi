import AppKit
import WebKit
import GobiModel

/// The preview of a Markdown file: gobid's rendered HTML in a web view that runs no scripts and loads nothing from outside.
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private(set) var loadCount = 0
    var onLoaded: () -> Void = {}

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel("Markdown preview")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(html: String) { web.loadHTMLString(MarkdownPreviewPage.wrap(html: html), baseURL: nil) }

    /// The text the preview shows, for the self-test.
    func text(_ done: @escaping (String) -> Void) {
        web.evaluateJavaScript("document.body.innerText") { result, _ in done(result as? String ?? "") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadCount += 1; onLoaded() }

    /// Links open in the browser when they are http or https; nothing else is followed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else { return decisionHandler(.allow) }
        if let url = navigationAction.request.url, MarkdownPreviewPage.opensExternally(url: url.absoluteString) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
}

/// A Markdown file's editor with the Source | Split | Preview switch above it (Markdown preview mock).
final class MarkdownHostView: NSView {
    private let editorView: NSView
    let preview = MarkdownPreviewView()
    private let modeControl = NSSegmentedControl(labels: MarkdownPreviewMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let note = NSTextField(labelWithString: "Preview shows Markdown only. Raw HTML and script links are removed.")
    private let content = NSStackView()
    private(set) var mode: MarkdownPreviewMode
    var onModeChanged: (MarkdownPreviewMode) -> Void = { _ in }

    init(editorView: NSView, mode: MarkdownPreviewMode) {
        self.editorView = editorView
        self.mode = mode
        super.init(frame: .zero)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .texturedRounded
        modeControl.setAccessibilityLabel("Markdown view")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 11)
        let bar = NSStackView(views: [modeControl, note, NSView()])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        content.orientation = .horizontal
        content.spacing = 0
        content.distribution = .fillEqually
        content.addArrangedSubview(editorView)
        content.addArrangedSubview(preview)
        let column = NSStackView(views: [bar, content])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor), content.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        apply(mode)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ newMode: MarkdownPreviewMode) {
        mode = newMode
        modeControl.selectedSegment = MarkdownPreviewMode.allCases.firstIndex(of: newMode) ?? 1
        editorView.isHidden = !newMode.showsSource
        preview.isHidden = !newMode.showsPreview
    }

    @objc private func modeChanged() {
        apply(MarkdownPreviewMode.allCases[max(0, modeControl.selectedSegment)])
        onModeChanged(mode)
    }
}
