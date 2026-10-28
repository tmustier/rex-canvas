import AppKit
import ApplicationServices
import WebKit

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CanvasWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Canvas {
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

    init(id: String, url: String, session: String, placeholder: String, agentBlock: String) {
        self.id = id
        self.url = url
        self.session = session
        self.placeholder = placeholder
        self.agentBlock = agentBlock
        window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .windowBackgroundColor
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        web = CanvasWebView(frame: window.contentView!.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.allowsBackForwardNavigationGestures = true
        window.contentView!.addSubview(web)
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
}

/// Background app that draws each canvas over its placeholder Rex pane and keeps it there.
final class Helper: NSObject, NSApplicationDelegate {
    private var canvases: [String: Canvas] = [:]
    private var server: IPCServer!
    private var hotUntil = Date.distantPast
    private var lastTick = Date.distantPast
    private var lastScan = Date.distantPast
    private var needsScan = true
    /// Canvases closed recently, so a dying placeholder's last registration doesn't reopen them.
    private var closedAt: [String: Date] = [:]
    private var suppressFocusSyncUntil = Date.distantPast
    private var eventStreams: [String: Process] = [:]
    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Helper.editMenu()
        server = IPCServer { [unowned self] request, reply in self.handle(request, reply) }
        do { try server.start() } catch {
            log("could not listen on \(Paths.socket): \(error)")
            exit(1)
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [unowned self] _ in self.tick(force: false) }
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [unowned self] _ in self.markHot(scan: true) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            self.handleKey(event) ? nil : event
        }
        log("helper ready on \(Paths.socket)")
    }

    // MARK: Requests

    private func handle(_ request: JSON, _ reply: @escaping (JSON) -> Void) {
        let command = request["command"] as? String ?? ""
        let id = request["id"] as? String ?? ""
        switch command {
        case "ping":
            reply(["ok": true, "pid": Int(getpid())])
        case "list":
            reply(["ok": true, "canvases": canvases.values.sorted { $0.id < $1.id }.map(describe)])
        case "ensure":
            if let canvas = canvases[id] {
                reply(["ok": true, "created": false, "canvas": describe(canvas)])
                return
            }
            if let closed = closedAt[id], Date().timeIntervalSince(closed) < 5 {
                reply(["ok": false, "error": "canvas \(id) is closing"])
                return
            }
            let canvas = Canvas(id: id, url: request["url"] as! String, session: request["session"] as! String,
                                placeholder: request["placeholder"] as! String, agentBlock: request["agent_block"] as! String)
            canvases[id] = canvas
            canvas.load(canvas.url)
            followEvents(session: canvas.session)
            markHot(scan: true)
            reply(["ok": true, "created": true, "canvas": describe(canvas)])
        case "quit":
            reply(["ok": true])
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            guard let canvas = canvases[id] ?? (id.isEmpty && canvases.count == 1 ? canvases.values.first : nil) else {
                reply(["ok": false, "error": "no canvas \(id.isEmpty ? "(pass --id)" : id)"])
                return
            }
            perform(command, on: canvas, request: request, reply: reply)
        }
    }

    private func perform(_ command: String, on canvas: Canvas, request: JSON, reply: @escaping (JSON) -> Void) {
        switch command {
        case "navigate":
            canvas.load(request["url"] as! String)
            reply(["ok": true, "canvas": describe(canvas)])
        case "reload":
            canvas.web.reload()
            reply(["ok": true])
        case "focus":
            focusCanvas(canvas)
            reply(["ok": true])
        case "close":
            close(canvas, closePlaceholder: request["from_placeholder"] as? Bool != true)
            reply(["ok": true])
        case "eval":
            canvas.web.evaluateJavaScript(request["js"] as! String) { value, error in
                if let error { reply(["ok": false, "error": error.localizedDescription]); return }
                reply(["ok": true, "value": Helper.jsonSafe(value)])
            }
        case "screenshot":
            let path = request["path"] as! String
            canvas.web.takeSnapshot(with: nil) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    reply(["ok": false, "error": error?.localizedDescription ?? "snapshot failed"])
                    return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    reply(["ok": true, "path": path])
                } catch { reply(["ok": false, "error": "\(error)"]) }
            }
        default:
            reply(["ok": false, "error": "unknown command \(command)"])
        }
    }

    private func describe(_ canvas: Canvas) -> JSON {
        [
            "id": canvas.id, "url": canvas.web.url?.absoluteString ?? canvas.url, "title": canvas.web.title ?? "",
            "session": canvas.session, "placeholder": canvas.placeholder, "agent_block": canvas.agentBlock,
            "visible": canvas.shown,
            "frame": [canvas.frame.minX, canvas.frame.minY, canvas.frame.width, canvas.frame.height].map { Int($0) },
        ]
    }

    private static func jsonSafe(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    // MARK: Placement

    /// Asks for 60 Hz placement for a short while; `scan` also asks for a full accessibility scan.
    private func markHot(scan: Bool = false) {
        hotUntil = Date().addingTimeInterval(0.6)
        if scan { needsScan = true }
    }

    /// Runs at 60 Hz while something is changing (mouse held, Rex events, app switches) and at 5 Hz otherwise.
    /// Between full scans it only re-reads each canvas pane's frame, which costs two accessibility calls.
    private func tick(force: Bool) {
        let now = Date()
        let hot = force || now < hotUntil || NSEvent.pressedMouseButtons != 0
        if !hot, now.timeIntervalSince(lastTick) < 0.2 { return }
        lastTick = now
        if canvases.isEmpty { return }
        if needsScan || now.timeIntervalSince(lastScan) >= 0.2 {
            needsScan = false
            lastScan = now
            layout()
        } else {
            follow()
        }
    }

    private func follow() {
        for canvas in canvases.values where canvas.shown {
            guard let terminal = canvas.terminal else { continue }
            let content = RexAX.frame(terminal)
            if content.isEmpty { needsScan = true; continue }
            let target = RexAX.appKitRect(content)
            if target != canvas.frame {
                canvas.window.setFrame(target, display: true)
                canvas.frame = target
            }
        }
    }

    private func layout() {
        guard let rex = RexAX.app(), !rex.isHidden else { canvases.values.forEach(hide); return }
        let pid = rex.processIdentifier
        observe(pid: pid)
        let panes = RexAX.panes(pid: pid)
        let windows = RexAX.onScreenWindows(pid: pid)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rexInFront = front == pid || front == getpid()

        for canvas in canvases.values {
            guard let pane = panes.first(where: { Helper.title($0.title, matches: canvas.id) }),
                  let rexWindow = windows.first(where: { $0.bounds == pane.windowFrame }) else {
                canvas.terminal = nil
                hide(canvas)
                continue
            }
            canvas.terminal = pane.terminal
            let target = RexAX.appKitRect(pane.content)
            if target != canvas.frame {
                canvas.window.setFrame(target, display: true)
                canvas.frame = target
            }
            if !canvas.shown || canvas.raisedForRex != rexInFront {
                if rexInFront {
                    // Stay above the Rex window while Rex or the canvas has focus.
                    canvas.window.level = .floating
                    canvas.window.orderFront(nil)
                } else {
                    // Another app is in front: sit directly above the Rex window so that app still covers us.
                    canvas.window.level = .normal
                    canvas.window.order(.above, relativeTo: rexWindow.number)
                }
                canvas.shown = true
                canvas.raisedForRex = rexInFront
            }
        }
        syncFocusFromRex(pid: pid, front: front, panes: panes)
    }

    private static func title(_ title: String, matches id: String) -> Bool {
        let tag = "canvas:\(id)"
        return title == tag || title.hasPrefix(tag + " ")
    }

    private func hide(_ canvas: Canvas) {
        guard canvas.shown else { return }
        canvas.window.orderOut(nil)
        canvas.shown = false
    }

    // MARK: Focus

    /// When Rex focuses a placeholder pane (by keyboard or click), hand the keyboard to its canvas.
    private func syncFocusFromRex(pid: pid_t, front: pid_t?, panes: [RexPane]) {
        guard front == pid, Date() > suppressFocusSyncUntil, let focused = RexAX.focusedElement(pid: pid) else { return }
        for canvas in canvases.values where canvas.shown {
            if let pane = panes.first(where: { Helper.title($0.title, matches: canvas.id) }), CFEqual(pane.terminal, focused) {
                focusCanvas(canvas)
                return
            }
        }
    }

    private func focusCanvas(_ canvas: Canvas) {
        NSApp.activate(ignoringOtherApps: true)
        canvas.window.makeKeyAndOrderFront(nil)
        canvas.window.makeFirstResponder(canvas.web)
        markHot(scan: true)
    }

    /// Moves Rex's focus to the agent pane first, so Rex doesn't hand focus straight back to the canvas.
    private func returnToRex(_ canvas: Canvas) {
        suppressFocusSyncUntil = Date().addingTimeInterval(0.5)
        Helper.rex(["focus", "-s", canvas.session, canvas.agentBlock])
        RexAX.app()?.activate()
        markHot(scan: true)
    }

    private func keyCanvas() -> Canvas? {
        canvases.values.first { $0.window.isKeyWindow }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let canvas = keyCanvas() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if flags.contains([.command, .option]), arrows.contains(event.keyCode) {
            returnToRex(canvas)
            return true
        }
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "w": close(canvas, closePlaceholder: true)
        case "r": canvas.web.reload()
        case "[": canvas.web.goBack()
        case "]": canvas.web.goForward()
        case "=", "+": canvas.web.pageZoom += 0.1
        case "-": canvas.web.pageZoom = max(0.3, canvas.web.pageZoom - 0.1)
        case "0": canvas.web.pageZoom = 1
        default: return false
        }
        return true
    }

    // MARK: Lifecycle

    private func close(_ canvas: Canvas, closePlaceholder: Bool) {
        let returning = canvas.window.isKeyWindow
        canvas.window.orderOut(nil)
        canvas.window.close()
        canvases[canvas.id] = nil
        closedAt[canvas.id] = Date()
        if closePlaceholder { Helper.rex(["block", "close", "-s", canvas.session, canvas.placeholder]) }
        if returning { returnToRex(canvas) }
        if !canvases.values.contains(where: { $0.session == canvas.session }) {
            eventStreams.removeValue(forKey: canvas.session)?.terminate()
        }
    }

    /// Follows a Rex session's events: layout changes trigger fast placement; a closed placeholder closes its canvas.
    private func followEvents(session: String) {
        guard eventStreams[session] == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rex", "events", "-s", session, "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
                DispatchQueue.main.async { self?.handleRexEvent(event) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.eventStreams[session] = nil }
        }
        do {
            try process.run()
            eventStreams[session] = process
        } catch { log("rex events failed: \(error)") }
    }

    private func handleRexEvent(_ event: JSON) {
        let type = event["type"] as? String ?? ""
        let block = event["block_id"] as? String ?? (event["payload"] as? JSON)?["block_id"] as? String
        if type == "block_closed", let block, let canvas = canvases.values.first(where: { $0.placeholder == block }) {
            close(canvas, closePlaceholder: false)
        }
        markHot(scan: true)
    }

    /// Accessibility notices from Rex (window moved or resized, focus changed) trigger an immediate placement.
    private func observe(pid: pid_t) {
        guard pid != observedPid else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observedPid = pid
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<Helper>.fromOpaque(refcon).takeUnretainedValue().axNotice(notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedUIElementChangedNotification,
                     kAXFocusedWindowChangedNotification, kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification, kAXApplicationHiddenNotification,
                     kAXApplicationShownNotification] {
            AXObserverAddNotification(created, application, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func axNotice(_ name: String) {
        let geometryOnly = name == kAXWindowMovedNotification || name == kAXWindowResizedNotification
        markHot(scan: !geometryOnly)
    }

    @discardableResult
    static func rex(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rex"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Accessory apps have no visible menu bar, but the menu still routes copy, paste and undo to the web view.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8))
}

func runHelper() -> Never {
    setsid()
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    let delegate = Helper()
    app.delegate = delegate
    app.run()
    exit(0)
}
