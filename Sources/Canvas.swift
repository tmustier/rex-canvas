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

/// The toolbar lays out its own items, so the URL bar never runs under the Ask agent button at narrow widths.
final class ToolbarView: NSVisualEffectView {
    var onResize: () -> Void = {}
    override func resizeSubviews(withOldSize oldSize: NSSize) { onResize() }
}

/// Receives `window.rexCanvas.ask(...)` from the page. Pages can only open the ask field, and their text
/// is shown as a hint, never as the question: sending always needs the person to type and press Enter.
private final class PageBridge: NSObject, WKScriptMessageHandler {
    var onAsk: (String) -> Void = { _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], body["type"] as? String == "ask" else { return }
        onAsk(body["text"] as? String ?? "")
    }
}

/// The page's only API: `window.rexCanvas.ask(hint)` opens the ask field. It runs in the page's own world,
/// so the page can replace it, which only affects that page.
private let pageAPIScript = """
window.rexCanvas = Object.freeze({
  ask(hint = '') { window.webkit.messageHandlers.rexCanvas.postMessage({ type: 'ask', text: String(hint) }); },
});
"""

/// Records the person's latest selection and click so the agent can ask about them. It runs in an isolated
/// script world (`Canvas.world`), before the page's scripts, so the page can neither see nor replace it.
/// The page and the canvas share the document, so selections, clicks and highlights are the real ones.
private let trackerScript = """
(() => {
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
      return { selection, click: lastClick, focused };
    },
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
    /// The isolated script world that holds the selection and click tracker.
    static let world = WKContentWorld.world(name: "rex-canvas")
    private static let askPlaceholder = "Ask the agent about this page. Your selection is included. Enter sends, Esc cancels."

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
            WKUserScript(source: trackerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Canvas.world))
        configuration.userContentController.addUserScript(
            WKUserScript(source: pageAPIScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        // Keys go to the page when the canvas becomes active, not to the first field in the toolbar.
        window.initialFirstResponder = web

        bridge.onAsk = { [weak self] hint in self?.showAsk(hint: hint) }
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
        let bar = ToolbarView(frame: NSRect(x: 0, y: top - height, width: width, height: height))
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

        addressField.font = .systemFont(ofSize: 12)
        addressField.textColor = .secondaryLabelColor
        addressField.placeholderString = "Enter a URL or file path (⌘L)"
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.cell?.isScrollable = true
        addressField.delegate = self
        addressField.onFocus = { [weak self] in self?.beginEditingAddress() }
        bar.addSubview(addressField)

        askField.font = .systemFont(ofSize: 12)
        askField.placeholderString = Canvas.askPlaceholder
        askField.bezelStyle = .roundedBezel
        askField.focusRingType = .none
        askField.delegate = self
        askField.isHidden = true
        bar.addSubview(askField)

        askButton.bezelStyle = .inline
        askButton.controlSize = .small
        askButton.font = .systemFont(ofSize: 11, weight: .medium)
        askButton.toolTip = "Ask the agent about this page (⌘⇧A)"
        askButton.target = self
        askButton.action = #selector(askButtonPressed)
        bar.addSubview(askButton)
        bar.onResize = { [weak self, unowned bar] in self?.layoutToolbar(width: bar.bounds.width) }
        layoutToolbar(width: width)
        return bar
    }

    /// Below this width the Ask agent button shows an icon instead of its label.
    private static let compactToolbarWidth: CGFloat = 380 // agent-default (not a user rule): 2026-10-29

    private func layoutToolbar(width: CGFloat) {
        let compact = width < Canvas.compactToolbarWidth
        if compact {
            askButton.title = ""
            askButton.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "Ask agent")
            askButton.imagePosition = .imageOnly
        } else {
            askButton.image = nil
            askButton.title = "Ask agent"
            askButton.imagePosition = .noImage
        }
        let buttonWidth: CGFloat = compact ? 28 : 92
        askButton.frame = NSRect(x: width - buttonWidth - 8, y: 5, width: buttonWidth, height: 20)
        let textX: CGFloat = 84
        let textFrame = NSRect(x: textX, y: 5, width: max(0, askButton.frame.minX - 6 - textX), height: 20)
        addressField.frame = textFrame
        askField.frame = textFrame
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
        // The field editor is still attached while this runs, so restore the short address once it has gone.
        DispatchQueue.main.async { [weak self] in self?.refreshTitle() }
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
    @objc private func askButtonPressed() { askField.isHidden ? showAsk() : hideAsk() }

    /// Runs a script in the isolated tracker world.
    func runTracker(_ script: String, _ done: ((Result<Any, Error>) -> Void)? = nil) {
        web.evaluateJavaScript(script, in: nil, in: Canvas.world, completionHandler: done)
    }

    // MARK: Ask

    /// Opens the ask field. A page-supplied hint is only a placeholder: it is never sent unless the person types it.
    func showAsk(hint: String = "") {
        guard shown else { return }
        // Save the page selection before focus leaves the page. Script calls run in order, ahead of the focus change.
        if askField.isHidden { runTracker("rexCanvas.pin(); null") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addressField.isHidden = true
        askField.isHidden = false
        let visibleHint = hint.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        askField.placeholderString = visibleHint.isEmpty ? Canvas.askPlaceholder : visibleHint
        window.makeFirstResponder(askField)
        askField.currentEditor()?.moveToEndOfDocument(nil)
    }

    private func hideAsk() {
        askField.isHidden = true
        addressField.isHidden = false
        window.makeFirstResponder(web)
        askField.placeholderString = Canvas.askPlaceholder
        runTracker("rexCanvas.unpin(); null")
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
