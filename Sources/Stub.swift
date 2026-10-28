import Foundation

/// Runs in the placeholder pane, which is the source of truth for its canvas:
/// - its terminal title tags the pane so the helper can find it on screen;
/// - every second it registers the canvas with the helper, starting the helper if needed,
///   so a helper restart brings the canvas back;
/// - its text is what a Rex client without the helper sees in place of the canvas.
func runStub(id: String, url: String, agentBlock: String) -> Never {
    let environment = ProcessInfo.processInfo.environment
    guard let session = environment["REX_SESSION"], let placeholder = environment["REX_BLOCK"] else {
        fail("stub must run in a Rex pane")
    }

    func draw() {
        let lines = [
            "\u{1b}]2;canvas:\(id)\u{07}\u{1b}[?25l\u{1b}[2J\u{1b}[H\u{1b}[1mcanvas:\(id)\u{1b}[0m",
            "",
            url,
            "",
            "\u{1b}[2mThe rex-canvas helper draws this page over this pane on the Mac that runs it.",
            "If you can read this, the canvas is hidden or you are on another Rex client.",
            "",
            "Close this pane to close the canvas.\u{1b}[0m",
        ]
        FileHandle.standardOutput.write(Data(lines.joined(separator: "\r\n").utf8))
    }

    let register = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    register.schedule(deadline: .now(), repeating: 1.0)
    register.setEventHandler {
        let request: JSON = ["command": "ensure", "id": id, "url": url, "session": session,
                             "placeholder": placeholder, "agent_block": agentBlock]
        if ipcRequest(request) == nil, ensureHelper() { _ = ipcRequest(request) }
    }
    register.resume()

    signal(SIGWINCH, SIG_IGN)
    let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    resize.setEventHandler(handler: draw)
    resize.resume()
    var sources: [Any] = [register, resize]

    for sig in [SIGHUP, SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            register.cancel()
            _ = ipcRequest(["command": "close", "id": id, "from_placeholder": true])
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    draw()
    withExtendedLifetime(sources) { dispatchMain() }
}
