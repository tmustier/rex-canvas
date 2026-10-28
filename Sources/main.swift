import Foundation

let usage = """
rex-canvas: open a web page in a canvas beside a Rex pane.

  rex-canvas open URL [--id ID] [--beside BLOCK] [--session SESSION] [--ratio PERCENT] [--split right|left|below|above]
  rex-canvas navigate URL [--id ID]
  rex-canvas list
  rex-canvas focus|reload|close [--id ID]
  rex-canvas context [--id ID]       what the person is looking at: page, selection, last click, page-provided context
  rex-canvas ask QUESTION [--id ID]  send a question with the page context to the agent pane, as the Ask agent field does
  rex-canvas eval JS [--id ID]
  rex-canvas screenshot PATH [--id ID]
  rex-canvas quit

open splits BLOCK (default $REX_BLOCK) and covers the new pane with the page. URL may be a URL, host:port or a file path.
Inside a canvas: cmd+shift+A (or the Ask agent button) sends a question with the selection to the agent pane;
cmd+option+arrow returns to Rex, cmd+W closes, cmd+R reloads, cmd+[ and cmd+] go back and forward.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rex-canvas: \(message)\n".utf8))
    exit(1)
}

func printJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ raw: ArraySlice<String>) {
        var iterator = raw.makeIterator()
        while let item = iterator.next() {
            if item.hasPrefix("--") {
                let name = String(item.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else {
                    guard let value = iterator.next() else { fail("--\(name) needs a value") }
                    options[name] = value
                }
            } else {
                positional.append(item)
            }
        }
    }
}

func request(_ body: JSON) -> JSON {
    guard let reply = ipcRequest(body) else { fail("helper is not running") }
    if reply["ok"] as? Bool != true { fail(reply["error"] as? String ?? "request failed") }
    return reply
}

func normalise(_ target: String) -> String {
    if target.contains("://") { return target }
    let expanded = (target as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
        return URL(fileURLWithPath: expanded).standardizedFileURL.absoluteString
    }
    if target.hasPrefix("localhost") || target.hasPrefix("127.0.0.1") { return "http://\(target)" }
    return "https://\(target)"
}

func defaultID(for url: String, taken: Set<String>) -> String {
    let parsed = URL(string: url)
    var base = parsed?.deletingPathExtension().lastPathComponent ?? ""
    if base.isEmpty || base == "/" { base = parsed?.host ?? "canvas" }
    base = String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(24))
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "canvas" }
    var candidate = base
    var counter = 2
    while taken.contains(candidate) {
        candidate = "\(base)-\(counter)"
        counter += 1
    }
    return candidate
}

func runRex(_ arguments: [String]) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["rex"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("could not run rex: \(error)") }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 { fail("rex \(arguments.prefix(2).joined(separator: " ")) failed") }
    return output
}

func openCanvas(_ args: Arguments) {
    guard let target = args.positional.first else { fail("open needs a URL") }
    let url = normalise(target)
    let environment = ProcessInfo.processInfo.environment
    guard let session = args.options["session"] ?? environment["REX_SESSION"] else { fail("pass --session or run inside Rex") }
    guard let beside = args.options["beside"] ?? environment["REX_BLOCK"] else { fail("pass --beside or run inside Rex") }
    guard ensureHelper() else { fail("helper did not start; see \(Paths.log)") }

    let existing = request(["command": "list"])["canvases"] as? [JSON] ?? []
    let taken = Set(existing.compactMap { $0["id"] as? String })
    if let id = args.options["id"], taken.contains(id) {
        printJSON(request(["command": "navigate", "id": id, "url": url])["canvas"]!)
        return
    }
    let id = args.options["id"] ?? defaultID(for: url, taken: taken)
    let split = runRex([
        "split", "-s", session, "-b", beside, "--split=\(args.options["split"] ?? "right")",
        "--ratio", args.options["ratio"] ?? "50", "--label", "canvas:\(id)", "--focus=false", "--json",
        "--", selfPath, "stub", id, url, beside,
    ])
    guard let created = (try? JSONSerialization.jsonObject(with: split)) as? JSON,
          let placeholder = (created["block_ids"] as? [String])?.first else { fail("rex split returned no block") }
    let reply = request([
        "command": "ensure", "id": id, "url": url, "session": session, "placeholder": placeholder, "agent_block": beside,
    ])
    printJSON(reply["canvas"]!)
}

signal(SIGPIPE, SIG_IGN)
let raw = CommandLine.arguments
guard raw.count >= 2 else { print(usage); exit(0) }
let args = Arguments(raw.dropFirst(2))
let id = args.options["id"] ?? ""

switch raw[1] {
case "helper":
    runHelper()
case "stub":
    guard args.positional.count >= 3 else { fail("stub needs ID, URL and agent block") }
    runStub(id: args.positional[0], url: args.positional[1], agentBlock: args.positional[2])
case "open":
    openCanvas(args)
case "navigate":
    guard let target = args.positional.first else { fail("navigate needs a URL") }
    printJSON(request(["command": "navigate", "id": id, "url": normalise(target)])["canvas"]!)
case "list":
    guard let reply = ipcRequest(["command": "list"]) else { printJSON([] as [Any]); exit(0) }
    printJSON(reply["canvases"] ?? [])
case "focus", "reload", "close":
    _ = request(["command": raw[1], "id": id])
case "ask":
    guard let text = args.positional.first else { fail("ask needs a question") }
    print(request(["command": "ask", "id": id, "text": text])["result"] as! String)
case "context":
    printJSON(request(["command": "context", "id": id])["context"] ?? [:])
case "eval":
    guard let js = args.positional.first else { fail("eval needs JavaScript") }
    printJSON(["value": request(["command": "eval", "id": id, "js": js])["value"] ?? NSNull()])
case "screenshot":
    guard let path = args.positional.first else { fail("screenshot needs a path") }
    let absolute = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path
    print(request(["command": "screenshot", "id": id, "path": absolute])["path"] as! String)
case "quit":
    if ipcRequest(["command": "quit"]) == nil { print("helper was not running") }
case "-h", "--help", "help":
    print(usage)
default:
    fail("unknown command \(raw[1])\n\n\(usage)")
}
