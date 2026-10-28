import AppKit
import ApplicationServices
import QuartzCore
import WebKit

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
    private var dividers: [CGRect] = []
    private var mouseWasDown = false
    private var dividerDrag: DividerDrag?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Helper.editMenu()
        server = IPCServer { [unowned self] request, reply in self.handle(request, reply) }
        do { try server.start() } catch {
            log("could not listen on \(Paths.socket): \(error)")
            exit(1)
        }
        // Tick on the display's refresh (120 Hz on ProMotion screens) so the canvas keeps up with Rex's own redraws.
        if let screen = NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(displayTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [unowned self] _ in self.markHot(scan: true) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            self.handleKey(event) ? nil : event
        }
        log("helper ready on \(Paths.socket)")
    }

    @objc private func displayTick() { tick(force: false) }

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
            canvas.onSubmitAsk = { [unowned self, unowned canvas] question in self.send(question, from: canvas) }
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
        case "context":
            pageContext(canvas) { context in reply(["ok": true, "context": context]) }
        case "ask":
            send(request["text"] as! String, from: canvas) { result in
                reply(["ok": result.hasPrefix("Sent"), "result": result, "error": result])
            }
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

    /// Asks for per-refresh placement for a short while; `scan` also asks for a full accessibility scan.
    private func markHot(scan: Bool = false) {
        hotUntil = Date().addingTimeInterval(0.6)
        if scan { needsScan = true }
    }

    /// Runs on every display refresh while something is changing (mouse held, Rex events, app switches) and at 5 Hz otherwise.
    /// Between full scans it only re-reads each canvas pane's frame, which costs two accessibility calls.
    private func tick(force: Bool) {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        if mouseDown, !mouseWasDown { beginDividerDrag() }
        if !mouseDown, mouseWasDown, dividerDrag != nil { endDividerDrag() }
        mouseWasDown = mouseDown
        if let drag = dividerDrag {
            followDivider(drag)
            return
        }
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
            place(canvas, content)
        }
    }

    private func place(_ canvas: Canvas, _ content: CGRect) {
        canvas.content = content
        let target = RexAX.appKitRect(content)
        if target != canvas.frame {
            canvas.window.setFrame(target, display: true)
            canvas.frame = target
        }
    }

    // MARK: Divider drags

    /// Which edge of a canvas a divider drag moves, the pointer and pane rectangle at the start, and the latest prediction.
    struct DividerDrag {
        enum Edge { case left, right, top, bottom }
        let canvasID: String
        let edge: Edge
        let startMouse: CGPoint
        let startContent: CGRect
        var predicted: CGRect
        var frames = 0
    }

    /// Asking Rex where the pane is during a drag waits on Rex's busy main thread, which leaves the canvas a frame
    /// or two behind. Instead, when a drag starts on a divider next to a canvas, move that canvas edge with the pointer
    /// and check against Rex once the button is released.
    private func beginDividerDrag() {
        let mouse = RexAX.mouseLocation()
        guard let divider = dividers.first(where: { $0.insetBy(dx: -4, dy: -4).contains(mouse) }),
              let rex = RexAX.app(), RexAX.windowOwner(at: mouse, excluding: getpid()) == rex.processIdentifier else { return }
        let vertical = divider.height > divider.width
        for canvas in canvases.values where canvas.shown {
            let pane = canvas.content
            let edge: DividerDrag.Edge?
            if vertical, divider.maxY > pane.minY, divider.minY < pane.maxY {
                edge = abs(divider.maxX - pane.minX) < 24 && divider.midX < pane.minX ? .left
                    : abs(divider.minX - pane.maxX) < 24 && divider.midX > pane.maxX ? .right : nil
            } else if !vertical, divider.maxX > pane.minX, divider.minX < pane.maxX {
                edge = abs(divider.maxY - pane.minY) < 24 && divider.midY < pane.minY ? .top
                    : abs(divider.minY - pane.maxY) < 24 && divider.midY > pane.maxY ? .bottom : nil
            } else {
                edge = nil
            }
            if let edge {
                dividerDrag = DividerDrag(canvasID: canvas.id, edge: edge, startMouse: mouse, startContent: pane, predicted: pane)
                return
            }
        }
    }

    private func followDivider(_ drag: DividerDrag) {
        guard let canvas = canvases[drag.canvasID] else { dividerDrag = nil; return }
        let mouse = RexAX.mouseLocation()
        let dx = mouse.x - drag.startMouse.x, dy = mouse.y - drag.startMouse.y
        var rect = drag.startContent
        switch drag.edge {
        case .left: rect.origin.x += dx; rect.size.width -= dx
        case .right: rect.size.width += dx
        case .top: rect.origin.y += dy; rect.size.height -= dy
        case .bottom: rect.size.height += dy
        }
        guard rect.width >= 40, rect.height >= 40 else { return }
        place(canvas, rect)
        dividerDrag?.predicted = rect
        dividerDrag?.frames += 1
    }

    private func endDividerDrag() {
        guard let drag = dividerDrag else { return }
        dividerDrag = nil
        layout()
        if let canvas = canvases[drag.canvasID] {
            let error = max(abs(canvas.content.minX - drag.predicted.minX), abs(canvas.content.maxX - drag.predicted.maxX),
                            abs(canvas.content.minY - drag.predicted.minY), abs(canvas.content.maxY - drag.predicted.maxY))
            log("divider drag on \(drag.canvasID): \(drag.frames) frames, off by \(Int(error.rounded())) pt at release")
        }
        markHot(scan: true)
    }

    private func layout() {
        guard let rex = RexAX.app(), !rex.isHidden else { canvases.values.forEach(hide); return }
        let pid = rex.processIdentifier
        observe(pid: pid)
        let (panes, dividers) = RexAX.scan(pid: pid)
        self.dividers = dividers
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
            place(canvas, pane.content)
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
        if flags == [.command, .shift], event.keyCode == 0 { // cmd+shift+A
            canvas.showAsk(prefill: "")
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

    // MARK: Asking the agent

    private func pageContext(_ canvas: Canvas, _ done: @escaping (JSON) -> Void) {
        let script = "JSON.stringify(window.rexCanvas ? window.rexCanvas.context() : { url: location.href, title: document.title })"
        canvas.web.evaluateJavaScript(script) { value, _ in
            let parsed = (value as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? JSON }
            done(parsed ?? ["url": canvas.web.url?.absoluteString ?? canvas.url, "title": canvas.web.title ?? ""])
        }
    }

    /// Types the question, with a one-line summary of the page context, into the agent pane and presses Enter.
    private func send(_ question: String, from canvas: Canvas, done: @escaping (String) -> Void = { _ in }) {
        pageContext(canvas) { context in
            let line = Helper.message(question: question, canvasID: canvas.id, context: context)
            DispatchQueue.global().async {
                let result = Helper.typeIntoAgent(line, session: canvas.session, block: canvas.agentBlock)
                DispatchQueue.main.async {
                    canvas.notice(result)
                    done(result)
                }
            }
        }
    }

    /// One line, with control characters removed, so page text can't press Enter or send terminal escape sequences.
    static func message(question: String, canvasID: String, context: JSON) -> String {
        func clean(_ text: String, _ limit: Int) -> String {
            let visible = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : $0
            }))
            let collapsed = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
        }
        var details = ["page \"\(clean(context["title"] as? String ?? "", 80))\" \(clean(context["url"] as? String ?? "", 200))"]
        if let selection = context["selection"] as? JSON, selection["current"] as? Bool == true,
           let text = selection["text"] as? String {
            let place = (selection["element"] as? String).map { " in \(clean($0, 120))" } ?? ""
            details.append("selected \"\(clean(text, 280))\"\(place)")
        } else if let click = context["click"] as? JSON, let element = click["element"] as? String {
            details.append("last clicked \(clean(element, 120))")
        }
        details.append("full context: rex-canvas context --id \(canvasID)")
        return "[canvas:\(canvasID)] \(clean(question, 2000)) (\(details.joined(separator: "; ")))"
    }

    /// Refuses to type into a plain shell, where the line would run as a command.
    static func typeIntoAgent(_ line: String, session: String, block: String) -> String {
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]
        guard let output = capture(["block", "call", "-s", session, "-b", block, "process"]),
              let process = (try? JSONSerialization.jsonObject(with: output)) as? JSON,
              let foreground = process["foreground"] as? JSON else {
            return "Not sent: the agent pane is gone"
        }
        let names = [foreground["name"] as? String, foreground["argv0"] as? String].compactMap { $0 }
            .map { ($0 as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if names.contains(where: shells.contains) { return "Not sent: the agent pane is a shell, not an agent" }
        guard rex(["send", "-s", session, "-b", block, line]) == 0,
              rex(["send-key", "-s", session, "-b", block, "enter"]) == 0 else { return "Not sent: rex send failed" }
        return "Sent to the agent"
    }

    static func capture(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rex"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: Lifecycle

    private func close(_ canvas: Canvas, closePlaceholder: Bool) {
        let returning = canvas.window.isKeyWindow
        canvas.window.orderOut(nil)
        canvas.window.close()
        canvas.tearDown()
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
