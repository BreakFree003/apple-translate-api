import Foundation

enum Log {
    /// 只闸住 INFO/DEBUG。ERROR 永远打得出来 —— 否则 `AT_LOG=0` 时「端口被占」
    /// 这类致命失败会变成零输出的 `exit 1`，后台服务上根本没法排查。
    /// 每条请求的错误日志由调用方自己看 `AT_LOG`（见 Router）。
    nonisolated(unsafe) static var verbose = true
    private static let lock = NSLock()
    private static let stamp = Date.ISO8601FormatStyle()

    static func info(_ message: String) {
        guard verbose else { return }
        emit("INFO", message)
    }

    static func error(_ message: String) { emit("ERROR", message) }

    static func debug(_ message: String) {
        guard verbose else { return }
        emit("DEBUG", message)
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "[\(stamp.format(Date()))] \(level) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
