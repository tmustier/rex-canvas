import Foundation

enum Paths {
    static let supportDir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/rex-canvas")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var socket: String { supportDir.appendingPathComponent("helper.sock").path }
    static var log: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/rex-canvas.log").path
    }
}

typealias JSON = [String: Any]

private func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        precondition(bytes.count < buffer.count, "socket path too long")
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        buffer[bytes.count] = 0
    }
    return addr
}

private func readLine(_ fd: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
        if buffer[count - 1] == UInt8(ascii: "\n") { break }
    }
    return data
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

/// Sends one JSON request to the helper and returns its JSON reply, or nil when no helper is listening.
func ipcRequest(_ request: JSON) -> JSON? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = unixAddress(Paths.socket)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    var payload = try! JSONSerialization.data(withJSONObject: request)
    payload.append(UInt8(ascii: "\n"))
    writeAll(fd, payload)
    let reply = readLine(fd)
    return (try? JSONSerialization.jsonObject(with: reply)) as? JSON
}

/// Accepts one JSON request per connection and answers it from the main thread.
final class IPCServer {
    typealias Handler = (JSON, @escaping (JSON) -> Void) -> Void
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    func start() throws {
        let path = Paths.socket
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = unixAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let line = readLine(client)
        var reply: JSON = ["ok": false, "error": "bad request"]
        if let request = (try? JSONSerialization.jsonObject(with: line)) as? JSON {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                self.handler(request) { response in
                    reply = response
                    done.signal()
                }
            }
            if done.wait(timeout: .now() + 30) == .timedOut { reply = ["ok": false, "error": "helper timed out"] }
        }
        var payload = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
        payload.append(UInt8(ascii: "\n"))
        writeAll(client, payload)
    }
}

let selfPath = Bundle.main.executablePath!

/// Starts the helper if no helper answers. Returns whether one answers afterwards.
@discardableResult
func ensureHelper() -> Bool {
    if ipcRequest(["command": "ping"]) != nil { return true }
    if !FileManager.default.fileExists(atPath: Paths.log) { FileManager.default.createFile(atPath: Paths.log, contents: nil) }
    let log = FileHandle(forWritingAtPath: Paths.log)!
    log.seekToEndOfFile()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: selfPath)
    process.arguments = ["helper"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    do { try process.run() } catch { return false }
    for _ in 0..<50 {
        if ipcRequest(["command": "ping"]) != nil { return true }
        usleep(100_000)
    }
    return false
}

