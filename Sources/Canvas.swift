import AppKit
import WebKit

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CanvasWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Toolbar buttons act on the first click, even when the canvas isn't the active window yet.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Receives `window.rexCanvas.ask(...)` from the page. Pages can only open the ask field;
/// sending always needs the person to press Enter.
private final class PageBridge: NSObject, WKScriptMessageHandler {
    var onAsk: (String) -> Void = { _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], body["type"] as? String == "ask" else { return }
        onAsk(body["text"] as? String ?? "")
    }
}

/// Injected into every page: records the person's latest selection and click so the agent can ask about them,
/// and exposes `window.rexCanvas.context()` and `window.rexCanvas.ask(text)`.
/// A page can add its own context by defining `window.rexCanvasContext = () => ({...})`.
private let pageScript = """
(() => {
  if (window.rexCanvas) return;
  const describe = (node) => {
    const parts = [];
    for (let el = node; el && el.nodeType === 1 && el !== document.documentElement && parts.length < 5; el = el.parentElement) {
      let part = el.localName;
      if (el.id) { parts.unshift(part + '#' + CSS.escape(el.id)); break; }
      const classes = [...el.classList].slice(0, 2).map((name) => '.' + CSS.escape(name)).join('');
      const siblings = el.parentElement ? [...el.parentElement.children].filter((child) => child.localName === el.localName) : [];
      if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')';
      parts.unshift(part + classes);
    }
    return parts.join(' > ');
  };
  const elementOf = (node) => node && (node.nodeType === 1 ? node : node.parentElement);
  let lastSelection = null;
  let lastClick = null;
  document.addEventListener('selectionchange', () => {
    const selection = getSelection();
    const text = selection ? String(selection).trim() : '';
    if (!text) return;
    const element = elementOf(selection.anchorNode);
    lastSelection = { text: text.slice(0, 4000), element: element ? describe(element) : null, at: new Date().toISOString() };
  });
  document.addEventListener('click', (event) => {
    const element = elementOf(event.target);
    if (!element) return;
    lastClick = { element: describe(element), text: (element.innerText || '').trim().slice(0, 300), at: new Date().toISOString() };
  }, true);
  window.rexCanvas = {
    context() {
      const focused = document.activeElement && document.activeElement !== document.body ? describe(document.activeElement) : null;
      const current = String(getSelection() || '').trim();
      const selection = lastSelection && { ...lastSelection, current: Boolean(current) && lastSelection.text === current.slice(0, 4000) };
      const context = { url: location.href, title: document.title, selection, click: lastClick, focused };
      if (typeof window.rexCanvasContext === 'function') {
        try { context.page = window.rexCanvasContext(); } catch (error) { context.page_error = String(error); }
      }
      return context;
    },
    ask(text = '') { window.webkit.messageHandlers.rexCanvas.postMessage({ type: 'ask', text: String(text) }); },
  };
})();
"""

/// One canvas: a borderless window with a slim toolbar and a web view, drawn over a Rex placeholder pane.
final class Canvas: NSObject, NSTextFieldDelegate {
    static let toolbarHeight: CGFloat = 30

    let id: String
    let session: String
    let placeholder: String
    let agentBlock: String
    let window: CanvasWindow
    let web: CanvasWebView
    var url: String
    var shown = false
    var raisedForRex = false
    var frame = NSRect.zero
    /// The placeholder pane's terminal element, re-read cheaply between full scans.
    var terminal: AXUIElement?
    /// The pane's terminal area in global top-left coordinates, as last placed.
    var content = CGRect.zero
    /// Called with the person's question when they press Enter in the ask field.
    var onSubmitAsk: (String) -> Void = { _ in }

    private let bridge = PageBridge()
    private let titleLabel = NSTextField(labelWithString: "")
    private let askField = NSTextField()
    private let askButton = FirstClickButton()
    private var observations: [NSKeyValueObservation] = []
    private var noticeUntil = Date.distantPast

    init(id: String, url: String, session: String, placeholder: String, agentBlock: String) {
        self.id = id
        self.url = url
        self.session = session
        self.placeholder = placeholder
        self.agentBlock = agentBlock
        window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(
            WKUserScript(source: pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(bridge, name: "rexCanvas")
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)
        web = CanvasWebView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Canvas.toolbarHeight),
                            configuration: configuration)
        super.init()

        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .windowBackgroundColor
        let root = window.contentView!
        web.autoresizingMask = [.width, .height]
        web.allowsBackForwardNavigationGestures = true
        root.addSubview(web)
        root.addSubview(makeToolbar(width: bounds.width, top: bounds.height))

        bridge.onAsk = { [weak self] text in self?.showAsk(prefill: text) }
        observations = [
            web.observe(\.title) { [weak self] _, _ in self?.refreshTitle() },
            web.observe(\.url) { [weak self] _, _ in self?.refreshTitle() },
        ]
    }

    func load(_ target: String) {
        url = target
        guard let parsed = URL(string: target) else { return }
        if parsed.isFileURL {
            web.loadFileURL(parsed, allowingReadAccessTo: parsed.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: parsed))
        }
    }

    func tearDown() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "rexCanvas")
        observations.removeAll()
    }

    // MARK: Toolbar

    private func makeToolbar(width: CGFloat, top: CGFloat) -> NSView {
        let height = Canvas.toolbarHeight
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: top - height, width: width, height: height))
        bar.material = .headerView
        bar.autoresizingMask = [.width, .minYMargin]

        let symbols: [(String, String, Selector)] = [
            ("chevron.left", "Back (⌘[)", #selector(goBack)),
            ("chevron.right", "Forward (⌘])", #selector(goForward)),
            ("arrow.clockwise", "Reload (⌘R)", #selector(reload)),
        ]
        for (index, (symbol, tip, action)) in symbols.enumerated() {
            let button = FirstClickButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            button.isBordered = false
            button.toolTip = tip
            button.frame = NSRect(x: 6 + CGFloat(index) * 24, y: 5, width: 22, height: 20)
            button.contentTintColor = .secondaryLabelColor
            bar.addSubview(button)
        }

        let textX: CGFloat = 84, buttonWidth: CGFloat = 92
        let textFrame = NSRect(x: textX, y: 6, width: width - textX - buttonWidth - 14, height: 18)
        titleLabel.frame = textFrame
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.autoresizingMask = [.width]
        bar.addSubview(titleLabel)

        askField.frame = textFrame.insetBy(dx: 0, dy: -1)
        askField.font = .systemFont(ofSize: 12)
        askField.placeholderString = "Ask the agent about this page. Your selection is included. Enter sends, Esc cancels."
        askField.bezelStyle = .roundedBezel
        askField.focusRingType = .none
        askField.autoresizingMask = [.width]
        askField.delegate = self
        askField.isHidden = true
        bar.addSubview(askField)

        askButton.title = "Ask agent"
        askButton.bezelStyle = .inline
        askButton.controlSize = .small
        askButton.font = .systemFont(ofSize: 11, weight: .medium)
        askButton.toolTip = "Ask the agent about this page (⌘⇧A)"
        askButton.target = self
        askButton.action = #selector(askButtonPressed)
        askButton.frame = NSRect(x: width - buttonWidth - 8, y: 5, width: buttonWidth, height: 20)
        askButton.autoresizingMask = [.minXMargin]
        bar.addSubview(askButton)
        return bar
    }

    private func refreshTitle() {
        guard Date() > noticeUntil else { return }
        let title = web.title ?? ""
        let place = web.url.map { $0.isFileURL ? $0.lastPathComponent : ($0.host ?? $0.absoluteString) } ?? ""
        titleLabel.stringValue = [title, place].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// Shows a short message in place of the title, such as confirming that a question was sent.
    func notice(_ text: String) {
        titleLabel.stringValue = text
        noticeUntil = Date().addingTimeInterval(2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.refreshTitle() }
    }

    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func reload() { web.reload() }
    @objc private func askButtonPressed() { askField.isHidden ? showAsk(prefill: "") : hideAsk() }

    // MARK: Ask

    func showAsk(prefill: String) {
        guard shown else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        titleLabel.isHidden = true
        askField.isHidden = false
        if !prefill.isEmpty { askField.stringValue = prefill }
        window.makeFirstResponder(askField)
        askField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func hideAsk() {
        askField.isHidden = true
        titleLabel.isHidden = false
        window.makeFirstResponder(web)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let question = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return true }
            askField.stringValue = ""
            hideAsk()
            onSubmitAsk(question)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hideAsk()
            return true
        }
        return false
    }
}
