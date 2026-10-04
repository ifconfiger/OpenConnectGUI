import Foundation
import os

/// Recent connection log kept in memory; the app fetches it with a provider message.
final class TunnelLog {
    private let lock = NSLock()
    private var lines: [String] = []
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
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
