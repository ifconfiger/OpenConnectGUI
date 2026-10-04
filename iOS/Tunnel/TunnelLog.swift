import Foundation
import os

/// Recent connection log kept in memory; the app fetches it with a provider message.
final class TunnelLog {
    private let lock = NSLock()
    private var lines: [String] = []
    private var lastErrorLine: String?
    private let logger = Logger(subsystem: "xyz.nows.openconnect.tunnel", category: "openconnect")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func append(_ message: String, error: Bool = false) {
        if error { logger.error("\(message, privacy: .public)") }
        else { logger.info("\(message, privacy: .public)") }
        lock.lock()
        lines.append("[\(formatter.string(from: Date()))] \(message)")
        if error { lastErrorLine = message }
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        lock.unlock()
    }

    /// Most recent error reported by libopenconnect, used to explain failures.
    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastErrorLine
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
