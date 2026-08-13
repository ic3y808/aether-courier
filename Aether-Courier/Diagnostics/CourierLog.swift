import Foundation
import OSLog

/// Central logger. Every meaningful step and every failure goes here so both
/// the user (Diagnostics window) and developers (log file + Console.app) can see
/// exactly what happened — no more silent failures.
///
/// Writes to:
///   • `~/Library/Logs/AetherCourier/courier.log` (tailable, readable by tools)
///   • os_log subsystem `com.aether.courier` (Console.app)
///   • an in-memory ring buffer surfaced by the Diagnostics window
final class CourierLog: @unchecked Sendable {
    static let shared = CourierLog()

    enum Level: String, Sendable {
        case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
    }

    let fileURL: URL
    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxBuffer = 1000
    private let oslog = Logger(subsystem: "com.aether.courier", category: "app")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/AetherCourier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("courier.log")
        log(.info, "──────── Aether Courier launched ────────", category: "app")
    }

    func log(_ level: Level, _ message: String, category: String = "app") {
        let line = "\(stamp.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > maxBuffer { buffer.removeFirst(buffer.count - maxBuffer) }
        appendToFile(line)
        lock.unlock()

        switch level {
        case .debug: oslog.debug("\(message, privacy: .public)")
        case .info:  oslog.info("\(message, privacy: .public)")
        case .warn:  oslog.warning("\(message, privacy: .public)")
        case .error: oslog.error("\(message, privacy: .public)")
        }
    }

    /// Recent lines for the in-app viewer (newest last).
    func recent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

// MARK: - Free-function conveniences (usable from any actor/thread)

func logInfo(_ message: String, category: String = "app")  { CourierLog.shared.log(.info,  message, category: category) }
func logWarn(_ message: String, category: String = "app")  { CourierLog.shared.log(.warn,  message, category: category) }
func logError(_ message: String, category: String = "app") { CourierLog.shared.log(.error, message, category: category) }
func logDebug(_ message: String, category: String = "app") { CourierLog.shared.log(.debug, message, category: category) }
