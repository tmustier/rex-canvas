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

/// The URL bar. It shows the page address while idle and the full URL, selected, while being edited.
final class AddressField: NSTextField {
    var onFocus: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus()
        return true
    }
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
  // The selection saved when the ask field opens. Focus moving to the field clears the page's own selection,
  // so it is kept here and painted with a custom highlight until the question is sent or cancelled.
  let pinned = null;
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
      const selection = pinned ? pinned.selection
        : lastSelection && { ...lastSelection, current: Boolean(current) && lastSelection.text === current.slice(0, 4000) };
      const context = { url: location.href, title: document.title, selection, click: lastClick, focused };
      if (typeof window.rexCanvasContext === 'function') {
        try { context.page = window.rexCanvasContext(); } catch (error) { context.page_error = String(error); }
      }
      return context;
    },
    ask(text = '') { window.webkit.messageHandlers.rexCanvas.postMessage({ type: 'ask', text: String(text) }); },
    pin() {
      const selection = getSelection();
      const text = selection ? String(selection).trim() : '';
      if (!text || !selection.rangeCount) { pinned = null; return; }
      const range = selection.getRangeAt(0).cloneRange();
      const element = elementOf(selection.anchorNode);
      pinned = { range, selection: { text: text.slice(0, 4000), element: element ? describe(element) : null, at: new Date().toISOString(), current: true } };
      if (window.Highlight && CSS.highlights) {
        if (!document.getElementById('rex-canvas-highlight')) {
          const style = document.createElement('style');
          style.id = 'rex-canvas-highlight';
          style.textContent = '::highlight(rex-canvas-ask) { background-color: rgba(64, 128, 255, 0.35); }';
          document.documentElement.appendChild(style);
        }
        CSS.highlights.set('rex-canvas-ask', new Highlight(range));
      }
    },
    unpin() {
      if (!pinned) return;
      const { range } = pinned;
      pinned = null;
      if (window.Highlight && CSS.highlights) CSS.highlights.delete('rex-canvas-ask');
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    },
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
    var frame = NSRect.zero
    /// The placeholder pane's terminal element, re-read cheaply between full scans.
    var terminal: AXUIElement?
    /// The pane's terminal area in global top-left coordinates, as last placed.
    var content = CGRect.zero
    /// Called with the person's question when they press Enter in the ask field.
    var onSubmitAsk: (String) -> Void = { _ in }

    private let bridge = PageBridge()
    private let addressField = AddressField()
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
        addressField.frame = textFrame.insetBy(dx: 0, dy: -1)
        addressField.font = .systemFont(ofSize: 12)
        addressField.textColor = .secondaryLabelColor
        addressField.placeholderString = "Enter a URL or file path (⌘L)"
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.cell?.isScrollable = true
        addressField.autoresizingMask = [.width]
        addressField.delegate = self
        addressField.onFocus = { [weak self] in self?.beginEditingAddress() }
        bar.addSubview(addressField)

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

    private var editingAddress: Bool { addressField.currentEditor() != nil }
    private var currentURL: String { web.url?.absoluteString ?? url }

    /// The address without its scheme, with file paths shortened to `~`.
    private var displayAddress: String {
        guard let page = web.url ?? URL(string: url) else { return url }
        if page.isFileURL { return (page.path as NSString).abbreviatingWithTildeInPath + (page.fragment.map { "#" + $0 } ?? "") }
        let text = page.absoluteString
        guard let range = text.range(of: "://") else { return text }
        return String(text[range.upperBound...])
    }

    private func refreshTitle() {
        addressField.toolTip = web.title
        guard Date() > noticeUntil, !editingAddress else { return }
        addressField.stringValue = displayAddress
    }

    func focusAddress() {
        guard shown else { return }
        if !askField.isHidden { hideAsk() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(addressField)
    }

    private func beginEditingAddress() {
        noticeUntil = .distantPast
        addressField.textColor = .labelColor
        addressField.stringValue = currentURL
        DispatchQueue.main.async { [weak self] in self?.addressField.currentEditor()?.selectAll(nil) }
    }

    private func endEditingAddress(navigateTo target: String?) {
        addressField.textColor = .secondaryLabelColor
        window.makeFirstResponder(web)
        if let target { load(normalise(target)) }
        addressField.stringValue = displayAddress
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === addressField else { return }
        addressField.textColor = .secondaryLabelColor
        refreshTitle()
    }

    /// Shows a short message in place of the address, such as confirming that a question was sent.
    func notice(_ text: String) {
        guard !editingAddress else { return }
        addressField.stringValue = text
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
        // Save the page selection before focus leaves the page. Script calls run in order, ahead of the focus change.
        if askField.isHidden { web.evaluateJavaScript("window.rexCanvas && window.rexCanvas.pin()") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addressField.isHidden = true
        askField.isHidden = false
        if !prefill.isEmpty { askField.stringValue = prefill }
        window.makeFirstResponder(askField)
        askField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func hideAsk() {
        askField.isHidden = true
        addressField.isHidden = false
        window.makeFirstResponder(web)
        web.evaluateJavaScript("window.rexCanvas && window.rexCanvas.unpin()")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === addressField {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let target = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                endEditingAddress(navigateTo: target.isEmpty ? nil : target)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                endEditingAddress(navigateTo: nil)
                return true
            }
            return false
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let question = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return true }
            askField.stringValue = ""
            // Read the page context, saved selection included, before hiding the field releases it.
            onSubmitAsk(question)
            hideAsk()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hideAsk()
            return true
        }
        return false
    }
}
