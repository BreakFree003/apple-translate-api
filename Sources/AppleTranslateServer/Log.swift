import Foundation

enum Log {
    nonisolated(unsafe) static var enabled = true
    private static let lock = NSLock()
    private static let stamp = Date.ISO8601FormatStyle()

    static func info(_ message: String) { emit("INFO", message) }
    static func error(_ message: String) { emit("ERROR", message) }
    static func debug(_ message: String) { emit("DEBUG", message) }

    private static func emit(_ level: String, _ message: String) {
        guard enabled else { return }
        let line = "[\(stamp.format(Date()))] \(level) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
