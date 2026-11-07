import Foundation

enum AppInfo {
    static let bundleID = "local.HotspotSaver"
    static let name = "Hotspot Saver"
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/HotspotSaver", isDirectory: true)
    static let config = support.appendingPathComponent("config.json")
    static let state = support.appendingPathComponent("state.json")
    static let log = home.appendingPathComponent("Library/Logs/HotspotSaver.log")

    static func ensure() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

enum Log {
    nonisolated(unsafe) static var echo = false
    private static let lock = NSLock()
    private static let maxBytes = 1_000_000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Appends one line. Never throws or raises: logging must not be able to crash the app.
    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        if echo { try? FileHandle.standardError.write(contentsOf: Data(line.utf8)) }
        let path = Paths.log.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            let old = path + ".1"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

/// Runs a command-line tool and returns its exit status and combined output.
/// Output goes to a temp file (not a pipe), so a background grandchild can't hang us,
/// and the call gives up after `timeout` seconds.
@discardableResult
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> (status: Int32, output: String) {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("hotspotsaver-\(UUID().uuidString).out")
    guard fm.createFile(atPath: tmp.path, contents: nil), let out = try? FileHandle(forWritingTo: tmp) else {
        return (-1, "couldn't create a temporary file")
    }
    defer {
        try? out.close()
        try? fm.removeItem(at: tmp)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = out
    p.standardError = out
    p.standardInput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in finished.signal() }
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if finished.wait(timeout: .now() + 2) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
        }
        return (-2, "timed out after \(Int(timeout)) s")
    }
    let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

@discardableResult
func shell(_ command: String, timeout: TimeInterval = 30) -> (status: Int32, output: String) {
    runTool("/bin/sh", ["-c", command], timeout: timeout)
}

func processAlive(_ pid: pid_t) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Seconds since boot, paused while the Mac sleeps (so timeouts don't expire during sleep).
func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// Inter-process messages between the CLI and the running menu-bar app.
/// Commands are "<request-id> <verb> [arg]"; replies are "<request-id>\n<text>".
enum IPC {
    static let command = Notification.Name("local.HotspotSaver.command")
    static let reply = Notification.Name("local.HotspotSaver.reply")
}
