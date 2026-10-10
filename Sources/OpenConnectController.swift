import Foundation
import Darwin

enum VPNError: LocalizedError {
    case invalidServer
    case invalidProxy
    case missingBinary
    case missingPassword
    case alreadyConnected
    case noConnection
    case passwordPipeTimeout
    case missingScript
    case disconnectTimedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer: String(localized: "Invalid server address. Enter a host name or an HTTPS URL.")
        case .invalidProxy: String(localized: "Invalid HTTP proxy address. Use http://host:port.")
        case .missingBinary: String(localized: "The bundled OpenConnect is missing. Please reinstall the app.")
        case .missingPassword: String(localized: "Enter and save the VPN password.")
        case .alreadyConnected: String(localized: "A VPN connection is already running.")
        case .noConnection: String(localized: "The connection has ended.")
        case .passwordPipeTimeout: String(localized: "Timed out waiting for OpenConnect to read the password.")
        case .missingScript: String(localized: "The bundled vpnc-script is missing; the network cannot be configured.")
        case .disconnectTimedOut: String(localized: "OpenConnect did not respond to the disconnect request; see the log.")
        case .commandFailed(let message): message
        }
    }
}

enum OpenConnectController {
    static var binary: String? {
        Bundle.main.path(forAuxiliaryExecutable: "openconnect")
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static var vpncScript: String? {
        Bundle.main.path(forResource: "vpnc-script", ofType: nil)
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static func sessionDirectory(for profile: VPNProfile) -> URL {
        ProfileStore.directory.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    static func logURL(for profile: VPNProfile) -> URL {
        sessionDirectory(for: profile).appendingPathComponent("openconnect.log")
    }

    private static func pidURL(for profile: VPNProfile) -> URL {
        URL(fileURLWithPath: "/var/run/vpnc/openconnectgui-\(getuid())-\(profile.id.uuidString).pid")
    }

    static func runningPIDs(for profile: VPNProfile) -> [Int32] {
        let result = runProcess("/usr/bin/pgrep", ["-x", "openconnect"])
        guard result.status == 0 else { return [] }
        let markers = [pidURL(for: profile).path,
                       sessionDirectory(for: profile).appendingPathComponent("openconnect.pid").path]
        return result.output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            .filter { pid in
                guard pid > 1 else { return false }
                let command = runProcess("/bin/ps", ["-p", String(pid), "-o", "command="])
                return command.status == 0 && markers.contains { command.output.contains("--pid-file=" + $0) }
            }
    }

    static func runningPID(for profile: VPNProfile) -> Int32? { runningPIDs(for: profile).first }

    static func connect(_ profile: VPNProfile, password: String) throws {
        guard !password.isEmpty else { throw VPNError.missingPassword }
        guard runningPID(for: profile) == nil else { throw VPNError.alreadyConnected }
        guard binary != nil else { throw VPNError.missingBinary }
        guard isValidServer(profile.server) else { throw VPNError.invalidServer }
        guard profile.hasValidProxy else { throw VPNError.invalidProxy }

        let directory = sessionDirectory(for: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let log = logURL(for: profile)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let heading = String(localized: "=== Connecting to \(profile.server) · \(timestamp) ===") + "\n"
        try Data(heading.utf8).write(to: log, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

        guard vpncScript != nil else { throw VPNError.missingScript }
        let result = PrivilegedCommand.shared.connect(profile, password: password)
        if result.status != 0 {
            throw VPNError.commandFailed(result.output.isEmpty ? String(localized: "Connection failed; see the log.") : result.output)
        }
        guard runningPID(for: profile) != nil else {
            throw VPNError.commandFailed(readLog(for: profile).isEmpty ? String(localized: "OpenConnect did not establish a connection.") : readLog(for: profile))
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let currentLog = readLog(for: profile)
            if currentLog.contains("OPENCONNECTGUI_NETWORK_READY") { return }
            if currentLog.contains("returned error") || runningPID(for: profile) == nil {
                try? disconnect(profile)
                throw VPNError.commandFailed(String(localized: "VPN authentication succeeded, but network configuration failed. See the log."))
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? disconnect(profile)
        throw VPNError.commandFailed(String(localized: "VPN network configuration timed out. See the log."))
    }

    static func disconnect(_ profile: VPNProfile) throws {
        guard runningPID(for: profile) != nil else { throw VPNError.noConnection }
        let result = PrivilegedCommand.shared.disconnect(profile)
        guard result.status == 0 else {
            throw VPNError.commandFailed(result.output.isEmpty ? String(localized: "Disconnect failed.") : result.output)
        }
        guard waitForExit(profile, seconds: 2) else { throw VPNError.disconnectTimedOut }
    }

    static func refreshNetwork(_ profile: VPNProfile) throws {
        let result = PrivilegedCommand.shared.refreshNetwork(profile)
        guard result.status == 0 else {
            throw VPNError.commandFailed(result.output.isEmpty ? String(localized: "Failed to re-establish the VPN connection.") : result.output)
        }
    }

    static func readLog(for profile: VPNProfile) -> String {
        guard let data = try? Data(contentsOf: logURL(for: profile)) else { return "" }
        return String(decoding: data.suffix(32_000), as: UTF8.self)
    }

    private static func waitForExit(_ profile: VPNProfile, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if runningPIDs(for: profile).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return runningPIDs(for: profile).isEmpty
    }

    private static func isValidServer(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.hasPrefix("-"),
              let components = URLComponents(string: value.hasPrefix("http") ? value : "https://" + value),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return true
    }

    private static func runProcess(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
