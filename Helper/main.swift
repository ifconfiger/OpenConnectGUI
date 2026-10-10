import Foundation
import Security
import Darwin
import Network
import CryptoKit

private let serviceName = HelperService.name

private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                 output: FileHandle? = nil) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.environment = environment
    let pipe = Pipe()
    task.standardOutput = output ?? pipe
    task.standardError = output ?? pipe
    do {
        try task.run()
        let data = output == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch { return (-1, error.localizedDescription) }
}

private func userDirectory(_ uid: uid_t) -> URL? {
    guard uid != 0, let account = getpwuid(uid), let home = String(validatingUTF8: account.pointee.pw_dir) else {
        return nil
    }
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/OpenConnectGUI/sessions")
}

private func sessionDirectory(_ uid: uid_t, _ id: UUID) -> URL? {
    userDirectory(uid)?.appendingPathComponent(id.uuidString)
}

private func isValidProfile(_ profile: VPNProfile) -> Bool {
    let server = profile.server
    guard !server.isEmpty, !server.hasPrefix("-"),
          !server.contains(where: { $0.isWhitespace || $0.isNewline }),
          let url = URLComponents(string: server.hasPrefix("http") ? server : "https://" + server),
          url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
          VPNProtocol(rawValue: profile.protocolName) != nil,
          !profile.username.isEmpty, !profile.username.hasPrefix("-"),
          !profile.username.contains(where: \.isNewline),
          !profile.authGroup.contains(where: \.isNewline),
          profile.username.utf8.count < 1024, profile.authGroup.utf8.count < 1024,
          profile.hasValidProxy else { return false }
    return true
}

private func isOwnedFile(_ path: String, uid: uid_t) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG &&
        info.st_uid == uid && (info.st_mode & 0o077) == 0
}

private func isOwnedDirectory(_ path: String, uid: uid_t) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR &&
        info.st_uid == uid && (info.st_mode & 0o077) == 0
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func executableDirectory() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(buffer.count)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().deletingLastPathComponent()
}

private func installedResource(_ name: String) -> String? {
    executableDirectory()?.deletingLastPathComponent()
        .appendingPathComponent("Resources").appendingPathComponent(name).path
}

/// OpenConnect and vpnc-script ship inside the app bundle next to this helper.
private func bundledOpenConnect() -> String? {
    executableDirectory()?.appendingPathComponent("openconnect").path
}

/// SHA-1 of the certificate the server presents, in the form accepted by
/// `openconnect --servercert`. Used when the profile ignores certificate errors.
private func serverCertificateFingerprint(_ server: String) -> String? {
    guard let components = URLComponents(string: server.hasPrefix("http") ? server : "https://" + server),
          let host = components.host,
          let port = NWEndpoint.Port(rawValue: UInt16(components.port ?? 443)) else { return nil }
    let queue = DispatchQueue(label: "xyz.nows.openconnect.certificate")
    let lock = NSLock()
    var fingerprint: String?
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        if let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first {
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            lock.lock()
            fingerprint = digest.map { String(format: "%02x", $0) }.joined()
            lock.unlock()
        }
        complete(true)
    }, queue)
    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: tls))
    let finished = DispatchSemaphore(value: 0)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready, .failed, .waiting, .cancelled: finished.signal()
        default: break
        }
    }
    connection.start(queue: queue)
    _ = finished.wait(timeout: .now() + 15)
    connection.cancel()
    lock.lock()
    defer { lock.unlock() }
    return fingerprint
}

/// Addresses OpenConnect may dial for `host`.
private func resolvedIPv4Addresses(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
    defer { freeaddrinfo(first) }
    var addresses: [String] = []
    var node: UnsafeMutablePointer<addrinfo>? = first
    while let current = node {
        if current.pointee.ai_family == AF_INET, let address = current.pointee.ai_addr {
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var raw = $0.pointee.sin_addr
                _ = inet_ntop(AF_INET, &raw, &text, socklen_t(text.count))
            }
            let value = String(cString: text)
            if !value.isEmpty, !addresses.contains(value) { addresses.append(value) }
        }
        node = current.pointee.ai_next
    }
    return addresses
}

/// A host route to the VPN server outlives its session when OpenConnect is killed or
/// the network changes. Its gateway is then off-link, so connect() fails with
/// EADDRNOTAVAIL before OpenConnect would run any script able to clean up.
private func pruneStaleServerRoutes(_ profile: VPNProfile, wrapper: String, script: String, log: FileHandle) {
    let server = profile.server
    guard let components = URLComponents(string: server.hasPrefix("http") ? server : "https://" + server),
          let host = components.host else { return }
    for address in resolvedIPv4Addresses(host) {
        let result = run(wrapper, [script, profile.dnsMode.rawValue],
                         environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                       "reason": "openconnectgui-prune", "VPNGATEWAY": address])
        let message = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { log.write(Data((message + "\n").utf8)) }
    }
}

/// Turn the tail of an OpenConnect log into something the user can act on. A rejected
/// password arrives as a bare 401 trailed by a note about HTTP Basic authentication
/// being disabled, which OpenConnect reports for every server because it disables
/// Basic at startup regardless of what the server offered; on its own that line sends
/// people looking for a proxy or protocol problem they do not have.
private func connectFailureReason(_ logPath: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    let tail = String(decoding: data, as: UTF8.self)
    if tail.contains("401 Authentication failed") || tail.contains("Got HTTP response: HTTP/1.1 401") {
        return "The server rejected the username or password. Check the username in the account settings and re-enter the password."
    }
    if tail.contains("Can't assign requested address") {
        return "Cannot reach the server: a host route points to a gateway that is gone. Try once more; if it still fails, look for a UGHS route to the server IP with netstat -rn -f inet."
    }
    if tail.contains("failed verification") {
        return "Server certificate verification failed. Check the server address, or turn on “Ignore Certificate Errors (Insecure)” in the account settings."
    }
    if tail.contains("Failed to connect to host") || tail.contains("Failed to open HTTPS connection") {
        return "Cannot reach the server. Check the network, server address and port."
    }
    return nil
}

private func recordedPIDs(_ paths: [String]) -> Set<pid_t> {
    Set(paths.compactMap { path in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    })
}

/// Finish route and DNS cleanup even when OpenConnect exited before receiving a stop request.
private func cleanupSavedSessions(_ profileID: UUID, knownPIDs: Set<pid_t>) -> (found: Bool, error: String?) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/var/run/vpnc") else {
        return (false, nil)
    }
    var found = false
    for name in names where name.hasPrefix("openconnectgui-") && name.hasSuffix(".env") {
        let pidText = String(name.dropFirst("openconnectgui-".count).dropLast(".env".count))
        guard let pid = pid_t(pidText), pid > 1 else { continue }
        let path = "/var/run/vpnc/" + name
        guard isOwnedFile(path, uid: 0), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
        var environment: [String: String] = [:]
        for item in data.split(separator: 0) {
            let pair = String(decoding: item, as: UTF8.self).split(separator: "=", maxSplits: 1)
            if pair.count == 2 { environment[String(pair[0])] = String(pair[1]) }
        }
        guard environment["VPNPID"] == pidText else { continue }
        if let savedID = environment["OPENCONNECTGUI_PROFILE_ID"] {
            guard savedID == profileID.uuidString else { continue }
        } else {
            guard knownPIDs.contains(pid) else { continue }
        }
        if matchingPIDsForProcess(pid) { continue }
        found = true
        environment["reason"] = "disconnect"
        guard let script = installedResource("vpnc-script") else { return (found, "vpnc-script not found.") }
        let result: (Int32, String)
        if let mode = environment["OPENCONNECTGUI_DNS_MODE"], let wrapper = installedResource("vpnc-wrapper.sh") {
            result = run(wrapper, [script, mode], environment: environment)
        } else {
            result = run(script, [], environment: environment)
            if result.0 == 0 { try? FileManager.default.removeItem(atPath: path) }
        }
        if result.0 != 0 { return (found, HelperMessage.cleanupFailedPrefix + result.1) }
    }
    return (found, nil)
}

private func matchingPIDsForProcess(_ pid: pid_t) -> Bool {
    let command = run("/bin/ps", ["-p", String(pid), "-o", "command="])
    return command.0 == 0 && command.1.contains("--pid-file=/var/run/vpnc/openconnectgui-")
}

private final class HelperSession: NSObject, OpenConnectHelperProtocol {
    private let uid: uid_t
    init(uid: uid_t) { self.uid = uid }

    func connect(_ profileData: Data, password: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = start(profileData, password: password)
            reply(result.0, result.1)
        }
    }

    private func start(_ data: Data, password: String) -> (Int32, String) {
        guard let profile = try? JSONDecoder().decode(VPNProfile.self, from: data),
              isValidProfile(profile), !password.isEmpty, password.utf8.count < 16_384,
              let directory = sessionDirectory(uid, profile.id),
              let sessions = userDirectory(uid),
              isOwnedDirectory(sessions.deletingLastPathComponent().path, uid: uid),
              isOwnedDirectory(sessions.path, uid: uid),
              isOwnedDirectory(directory.path, uid: uid),
              isOwnedFile(directory.appendingPathComponent("openconnect.log").path, uid: uid) else {
            return (-1, "Invalid connection parameters or session directory.")
        }
        guard let binary = bundledOpenConnect(), FileManager.default.isExecutableFile(atPath: binary) else {
            return (-1, "The bundled OpenConnect is missing. Please reinstall the app.")
        }
        guard let vpncScript = installedResource("vpnc-script"),
              FileManager.default.isExecutableFile(atPath: vpncScript) else { return (-1, "vpnc-script not found.") }
        guard let wrapper = installedResource("vpnc-wrapper.sh"),
              FileManager.default.isExecutableFile(atPath: wrapper) else {
            return (-1, "The bundled network script was not found.")
        }
        let pidFile = "/var/run/vpnc/openconnectgui-\(uid)-\(profile.id.uuidString).pid"
        let oldPidFile = directory.appendingPathComponent("openconnect.pid").path
        if !matchingPIDs([pidFile, oldPidFile]).isEmpty { return (-1, "A VPN connection is already running.") }
        if let error = cleanupSavedSessions(profile.id, knownPIDs: recordedPIDs([pidFile, oldPidFile])).error {
            return (-1, error)
        }
        do {
            try FileManager.default.createDirectory(atPath: "/var/run/vpnc", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch { return (-1, error.localizedDescription) }
        _ = unlink(pidFile)
        let logPath = directory.appendingPathComponent("openconnect.log").path
        let fd = open(logPath, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { return (-1, "Could not open the connection log.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == uid, (info.st_mode & 0o077) == 0 else {
            close(fd)
            return (-1, "The connection log has unsafe permissions.")
        }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        pruneStaleServerRoutes(profile, wrapper: wrapper, script: vpncScript, log: log)
        let script = shellQuote(wrapper) + " " + shellQuote(vpncScript) + " " + profile.dnsMode.rawValue
        var args = ["--background", "--non-inter", "--passwd-on-stdin", "--pid-file=\(pidFile)",
                    "--protocol=\(profile.protocolName)", "--user=\(profile.username)",
                    "--reconnect-timeout=\(profile.autoReconnect ? 15 : 0)", "--script=\(script)"]
        if profile.autoReconnect { args.append("--force-dpd=30") }
        if profile.proxyEnabled { args.append("--proxy=\(profile.proxyURL)") }
        else { args.append("--no-proxy") }
        if !profile.authGroup.isEmpty { args.append("--authgroup=\(profile.authGroup)") }
        log.write(Data((profile.proxyEnabled ? "Route: HTTP proxy \(profile.proxyURL)\n" : "Route: direct\n").utf8))
        if profile.ignoreCertificateErrors {
            guard let fingerprint = serverCertificateFingerprint(profile.server) else {
                return (-1, "Could not read the server certificate.")
            }
            log.write(Data("Ignoring certificate errors; trusting server certificate SHA1 \(fingerprint)\n".utf8))
            args.append("--servercert=\(fingerprint)")
        }
        args.append(profile.server)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        task.standardOutput = log
        task.standardError = log
        // The bundled OpenSSL trusts the macOS system CA bundle.
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SSL_CERT_FILE": "/etc/ssl/cert.pem",
                            "OPENCONNECTGUI_PROFILE_ID": profile.id.uuidString,
                            "OPENCONNECTGUI_DNS_MODE": profile.dnsMode.rawValue]
        let input = Pipe()
        task.standardInput = input
        do {
            try task.run()
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
            try input.fileHandleForWriting.close()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return (0, "") }
            return (task.terminationStatus,
                    connectFailureReason(logPath) ?? "OpenConnect failed to connect; see the log.")
        } catch { return (-1, error.localizedDescription) }
    }

    func disconnect(_ profileID: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = stop(profileID)
            reply(result.0, result.1)
        }
    }

    func cleanup(_ profileID: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let id = UUID(uuidString: profileID) else { reply(-1, "Invalid connection ID."); return }
            let result = cleanupSavedSessions(id, knownPIDs: [])
            reply(result.error == nil ? 0 : -1, result.error ?? "")
        }
    }

    func refreshNetwork(_ profileID: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let id = UUID(uuidString: profileID), let directory = sessionDirectory(uid, id) else {
                reply(-1, "Invalid connection ID.")
                return
            }
            let pidFiles = ["/var/run/vpnc/openconnectgui-\(uid)-\(id.uuidString).pid",
                            directory.appendingPathComponent("openconnect.pid").path]
            let pids = matchingPIDs(pidFiles)
            guard !pids.isEmpty else { reply(-1, "The connection has ended."); return }
            let succeeded = pids.map { kill($0, SIGUSR2) == 0 }.allSatisfy { $0 }
            reply(succeeded ? 0 : -1, succeeded ? "" : "Could not tell OpenConnect to reconnect.")
        }
    }

    private func stop(_ profileID: String) -> (Int32, String) {
        guard let id = UUID(uuidString: profileID), let directory = sessionDirectory(uid, id) else {
            return (-1, "Invalid connection ID.")
        }
        let pidFiles = ["/var/run/vpnc/openconnectgui-\(uid)-\(id.uuidString).pid",
                        directory.appendingPathComponent("openconnect.pid").path]
        var pids = matchingPIDs(pidFiles)
        let knownPIDs = recordedPIDs(pidFiles).union(pids)
        if !pids.isEmpty {
            for pid in pids { _ = kill(pid, SIGTERM) }
            if !waitForExit(pidFiles, seconds: 5) {
                pids = matchingPIDs(pidFiles)
                for pid in pids { _ = kill(pid, SIGINT) }
            }
            if !waitForExit(pidFiles, seconds: 3) {
                pids = matchingPIDs(pidFiles)
                for pid in pids { _ = kill(pid, SIGKILL) }
            }
        }
        guard waitForExit(pidFiles, seconds: 2) else { return (-1, "OpenConnect did not respond to the disconnect request.") }
        let cleanup = cleanupSavedSessions(id, knownPIDs: knownPIDs)
        if let error = cleanup.error { return (-1, error) }
        return !knownPIDs.isEmpty || cleanup.found ? (0, "") : (-1, "The connection has ended.")
    }
}

private func matchingPIDs(_ pidFiles: [String]) -> [pid_t] {
    let result = run("/usr/bin/pgrep", ["-x", "openconnect"])
    guard result.0 == 0 else { return [] }
    return result.1.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.filter { pid in
        guard pid > 1 else { return false }
        let command = run("/bin/ps", ["-p", String(pid), "-o", "command="])
        let owner = run("/bin/ps", ["-p", String(pid), "-o", "uid="])
        return command.0 == 0 && owner.0 == 0 && owner.1.trimmingCharacters(in: .whitespacesAndNewlines) == "0" &&
            pidFiles.contains { command.1.contains("--pid-file=" + $0) }
    }
}

private func waitForExit(_ pidFiles: [String], seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if matchingPIDs(pidFiles).isEmpty { return true }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return matchingPIDs(pidFiles).isEmpty
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: OpenConnectHelperProtocol.self)
        connection.exportedObject = HelperSession(uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let info = information as? [String: Any] else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}

guard geteuid() == 0, let team = ownTeamIdentifier() else { exit(1) }
let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"xyz.nows.openconnect\""
private let delegate = HelperDelegate(requirement: requirement)
private let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
