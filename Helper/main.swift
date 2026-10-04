import Foundation
import Security
import Darwin

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
          profile.username.utf8.count < 1024, profile.authGroup.utf8.count < 1024 else { return false }
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
            return (-1, "连接参数或会话目录无效。")
        }
        guard let binary = bundledOpenConnect(), FileManager.default.isExecutableFile(atPath: binary) else {
            return (-1, "App 内置的 OpenConnect 缺失，请重新安装应用。")
        }
        guard let vpncScript = installedResource("vpnc-script"),
              FileManager.default.isExecutableFile(atPath: vpncScript) else { return (-1, "未找到 vpnc-script。") }
        guard let wrapper = installedResource("vpnc-wrapper.sh"),
              FileManager.default.isExecutableFile(atPath: wrapper) else {
            return (-1, "未找到内置网络脚本。")
        }
        let pidFile = "/var/run/vpnc/openconnectgui-\(uid)-\(profile.id.uuidString).pid"
        let oldPidFile = directory.appendingPathComponent("openconnect.pid").path
        if !matchingPIDs([pidFile, oldPidFile]).isEmpty { return (-1, "已有 VPN 连接正在运行。") }
        do {
            try FileManager.default.createDirectory(atPath: "/var/run/vpnc", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch { return (-1, error.localizedDescription) }
        _ = unlink(pidFile)
        let logPath = directory.appendingPathComponent("openconnect.log").path
        let fd = open(logPath, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { return (-1, "无法打开连接日志。") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == uid, (info.st_mode & 0o077) == 0 else {
            close(fd)
            return (-1, "连接日志权限不安全。")
        }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let script = shellQuote(wrapper) + " " + shellQuote(vpncScript) + " " + profile.dnsMode.rawValue
        var args = ["--background", "--non-inter", "--passwd-on-stdin", "--pid-file=\(pidFile)",
                    "--protocol=\(profile.protocolName)", "--user=\(profile.username)",
                    "--reconnect-timeout=\(profile.autoReconnect ? 15 : 0)", "--script=\(script)"]
        if profile.autoReconnect { args.append("--force-dpd=30") }
        if !profile.authGroup.isEmpty { args.append("--authgroup=\(profile.authGroup)") }
        args.append(profile.server)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        task.standardOutput = log
        task.standardError = log
        // The bundled OpenSSL trusts the macOS system CA bundle.
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SSL_CERT_FILE": "/etc/ssl/cert.pem"]
        let input = Pipe()
        task.standardInput = input
        do {
            try task.run()
            try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
            try input.fileHandleForWriting.close()
            task.waitUntilExit()
            return (task.terminationStatus, task.terminationStatus == 0 ? "" : "OpenConnect 连接失败，请查看日志。")
        } catch { return (-1, error.localizedDescription) }
    }

    func disconnect(_ profileID: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = stop(profileID)
            reply(result.0, result.1)
        }
    }

    func refreshNetwork(_ profileID: String, reply: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let id = UUID(uuidString: profileID), let directory = sessionDirectory(uid, id) else {
                reply(-1, "连接 ID 无效。")
                return
            }
            let pidFiles = ["/var/run/vpnc/openconnectgui-\(uid)-\(id.uuidString).pid",
                            directory.appendingPathComponent("openconnect.pid").path]
            let pids = matchingPIDs(pidFiles)
            guard !pids.isEmpty else { reply(-1, "连接已结束。"); return }
            let succeeded = pids.map { kill($0, SIGUSR2) == 0 }.allSatisfy { $0 }
            reply(succeeded ? 0 : -1, succeeded ? "" : "无法通知 OpenConnect 重新连接。")
        }
    }

    private func stop(_ profileID: String) -> (Int32, String) {
        guard let id = UUID(uuidString: profileID), let directory = sessionDirectory(uid, id) else {
            return (-1, "连接 ID 无效。")
        }
        let pidFiles = ["/var/run/vpnc/openconnectgui-\(uid)-\(id.uuidString).pid",
                        directory.appendingPathComponent("openconnect.pid").path]
        var pids = matchingPIDs(pidFiles)
        guard !pids.isEmpty else { return (-1, "连接已结束。") }
        for pid in pids { _ = kill(pid, SIGTERM) }
        if waitForExit(pidFiles, seconds: 5) { return (0, "") }
        pids = matchingPIDs(pidFiles)
        for pid in pids { _ = kill(pid, SIGINT) }
        if waitForExit(pidFiles, seconds: 3) { return (0, "") }
        pids = matchingPIDs(pidFiles)
        for pid in pids { _ = kill(pid, SIGKILL) }
        for pid in pids {
            let state = "/var/run/vpnc/openconnectgui-\(pid).env"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: state)) else { continue }
            var environment: [String: String] = [:]
            for item in data.split(separator: 0) {
                let pair = String(decoding: item, as: UTF8.self).split(separator: "=", maxSplits: 1)
                if pair.count == 2 { environment[String(pair[0])] = String(pair[1]) }
            }
            environment["reason"] = "disconnect"
            if let script = installedResource("vpnc-script") { _ = run(script, [], environment: environment) }
            try? FileManager.default.removeItem(atPath: state)
        }
        return waitForExit(pidFiles, seconds: 2) ? (0, "") : (-1, "OpenConnect 没有响应断开请求。")
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
