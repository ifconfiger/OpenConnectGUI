import Foundation
import NetworkExtension

/// Runs libopenconnect on a dedicated thread and keeps the tunnel alive:
/// network changes trigger an immediate reconnect, lost sessions are
/// re-authenticated with the saved credentials, and authentication failures
/// stop the tunnel instead of retrying a wrong password.
final class OpenConnectTunnel {
    enum TunnelError: LocalizedError {
        case authentication(String)
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .authentication(let message), .connection(let message): message
            }
        }
    }

    private enum Outcome {
        case stopped
        case authenticationFailed(String)
        case failed(String)
        case disconnected(String)
    }

    /// Invoked once when the gateway rejects the saved credentials.
    var onAuthenticationFailure: (() -> Void)?

    private weak var provider: NEPacketTunnelProvider?
    private let profile: VPNProfile
    private let password: String
    private let log: TunnelLog
    private let bridge: PacketFlowBridge
    private let condition = NSCondition()
    private var stopping = false
    private var networkAvailable = true
    private var networkGeneration = 0
    private var session: OpaquePointer?
    private var inMainLoop = false
    private var startCompletion: ((Error?) -> Void)?
    private var stopCompletions: [() -> Void] = []
    private var finished = false
    private var appliedSettingsSignature: String?

    init(provider: NEPacketTunnelProvider, profile: VPNProfile, password: String, log: TunnelLog) {
        self.provider = provider
        self.profile = profile
        self.password = password
        self.log = log
        bridge = PacketFlowBridge(flow: provider.packetFlow)
    }

    func start(completion: @escaping (Error?) -> Void) {
        startCompletion = completion
        let thread = Thread { [self] in run() }
        thread.name = "OpenConnect"
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop(completion: @escaping () -> Void) {
        condition.lock()
        if finished {
            condition.unlock()
            completion()
            return
        }
        stopping = true
        stopCompletions.append(completion)
        if let session { ocs_session_send_command(session, CChar(UInt8(ascii: "x"))) }
        condition.broadcast()
        condition.unlock()
    }

    /// Called whenever the provider's default path changes.
    func networkChanged(available: Bool) {
        condition.lock()
        let regained = available && !networkAvailable
        networkAvailable = available
        networkGeneration += 1
        // A paused main loop returns 0 and is restarted at once, so a live
        // session reconnects over the new interface with its existing cookie.
        if available, inMainLoop, let session {
            log.append(regained ? "网络已恢复，正在重新连接。" : "网络已切换，正在重新连接。")
            ocs_session_send_command(session, CChar(UInt8(ascii: "p")))
        }
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Connection loop

    private func run() {
        var established = false
        var failures = 0
        var finalError: Error?

        while !isStopping {
            if established, !waitForNetwork() { break }
            let outcome = connectOnce(established: &established)
            switch outcome {
            case .stopped:
                break
            case .authenticationFailed(let message):
                finalError = TunnelError.authentication(message)
            case .failed(let message), .disconnected(let message):
                if case .disconnected = outcome { failures = 0 }
                guard established, profile.autoReconnect else {
                    finalError = TunnelError.connection(message)
                    break
                }
                failures += 1
                provider?.reasserting = true
                let delay = min(60, 2 << min(failures, 5))
                log.append("\(message) \(delay) 秒后重新连接（第 \(failures) 次）。", error: true)
                pause(seconds: TimeInterval(delay))
                continue
            }
            break
        }
        finish(error: finalError, established: established)
    }

    private func connectOnce(established: inout Bool) -> Outcome {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newSession = ocs_session_new(profile.protocolName, profile.username, password,
                                               profile.authGroup, { context, level, message in
            guard let context, let message else { return }
            let tunnel = Unmanaged<OpenConnectTunnel>.fromOpaque(context).takeUnretainedValue()
            tunnel.log.append(String(cString: message), error: level == PRG_ERR)
        }, { context in
            guard let context else { return }
            Unmanaged<OpenConnectTunnel>.fromOpaque(context).takeUnretainedValue().sessionReconnected()
        }, context) else {
            return .failed("无法初始化 OpenConnect。")
        }

        condition.lock()
        if stopping {
            condition.unlock()
            ocs_session_free(newSession)
            return .stopped
        }
        session = newSession
        condition.unlock()
        defer {
            condition.lock()
            session = nil
            inMainLoop = false
            condition.unlock()
            ocs_session_free(newSession)
        }

        log.append("正在连接 \(profile.server)…")
        let connectResult = ocs_session_connect(newSession, serverURL)
        if isStopping { return .stopped }
        if connectResult != 0 {
            if ocs_session_auth_failed(newSession) != 0 {
                return .authenticationFailed("VPN 认证失败：保存的账号或密码无效，或服务器要求二次验证。请在 App 中更新后重新连接。")
            }
            return .failed("无法连接 VPN 服务器：\(log.lastError ?? errorText(connectResult))")
        }

        let vpninfo = ocs_session_vpninfo(newSession)
        guard let settings = networkSettings(vpninfo) else { return .failed("服务器没有分配 VPN 地址。") }
        if let error = apply(settings.settings) {
            return .failed("无法应用 VPN 网络设置：\(error.localizedDescription)")
        }
        appliedSettingsSignature = settings.signature
        _ = openconnect_setup_dtls(vpninfo, 60)
        do {
            let descriptor = try bridge.makeTunnelDescriptor()
            guard openconnect_setup_tun_fd(vpninfo, descriptor) == 0 else {
                close(descriptor)
                return .failed("无法建立数据通道。")
            }
        } catch {
            return .failed("无法建立数据通道：\(error.localizedDescription)")
        }

        log.append("VPN 已连接。")
        if !established {
            established = true
            completeStart(nil)
        }
        provider?.reasserting = false

        var result: Int32 = 0
        repeat {
            condition.lock()
            inMainLoop = !stopping
            let shouldRun = inMainLoop
            condition.unlock()
            guard shouldRun else { return .stopped }
            result = openconnect_mainloop(vpninfo, profile.autoReconnect ? 60 : 0, RECONNECT_INTERVAL_MIN)
            condition.lock()
            inMainLoop = false
            condition.unlock()
        } while result == 0 && !isStopping

        if isStopping || result == -EINTR { return .stopped }
        switch result {
        case -EPERM: return .disconnected("登录会话已过期。")
        case -EPIPE: return .disconnected("服务器结束了会话。")
        default: return .disconnected("VPN 连接中断（\(errorText(result))）。")
        }
    }

    /// libopenconnect calls this on its own thread after it re-established
    /// the session; the gateway may have handed out a different address.
    private func sessionReconnected() {
        provider?.reasserting = false
        condition.lock()
        let current = session
        condition.unlock()
        guard let current, let settings = networkSettings(ocs_session_vpninfo(current)),
              settings.signature != appliedSettingsSignature else { return }
        if let error = apply(settings.settings) {
            log.append("更新 VPN 网络设置失败：\(error.localizedDescription)", error: true)
        } else {
            appliedSettingsSignature = settings.signature
        }
    }

    private func finish(error: Error?, established: Bool) {
        bridge.stop()
        if let error { log.append(error.localizedDescription, error: true) }
        if case .authentication = error as? TunnelError { onAuthenticationFailure?() }
        condition.lock()
        finished = true
        let completions = stopCompletions
        let wasStopping = stopping
        condition.unlock()

        if !established {
            completeStart(transferable(error ?? TunnelError.connection("连接已取消。")))
        } else if !wasStopping {
            provider?.cancelTunnelWithError(error.map(transferable))
        }
        completions.forEach { $0() }
    }

    /// Errors reach the app through the system, which only keeps NSError
    /// domain, code and userInfo; a Swift enum would lose its message.
    private func transferable(_ error: Error) -> NSError {
        let code: Int
        switch error as? TunnelError {
        case .authentication: code = 10
        case .connection: code = 11
        case nil: return error as NSError
        }
        return NSError(domain: "xyz.nows.openconnect.tunnel", code: code,
                       userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
    }

    private func completeStart(_ error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }

    // MARK: - Waiting

    private var isStopping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopping
    }

    private func waitForNetwork() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !networkAvailable && !stopping { log.append("等待网络恢复…") }
        while !networkAvailable && !stopping {
            condition.wait(until: Date().addingTimeInterval(30))
        }
        return !stopping
    }

    /// Sleeps for the back-off delay, waking early when the network changes.
    private func pause(seconds: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let generation = networkGeneration
        let deadline = Date().addingTimeInterval(seconds)
        while !stopping && generation == networkGeneration && Date() < deadline {
            condition.wait(until: deadline)
        }
    }

    // MARK: - Network settings

    private var serverURL: String {
        profile.server.lowercased().hasPrefix("https://") ? profile.server : "https://" + profile.server
    }

    private func apply(_ settings: NEPacketTunnelNetworkSettings) -> Error? {
        guard let provider else { return TunnelError.connection("VPN 扩展已退出。") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            result = error
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func networkSettings(_ vpninfo: OpaquePointer?) -> (settings: NEPacketTunnelNetworkSettings, signature: String)? {
        var infoPointer: UnsafePointer<oc_ip_info>?
        guard openconnect_get_ip_info(vpninfo, &infoPointer, nil, nil) == 0, let info = infoPointer?.pointee else {
            return nil
        }
        let address = string(info.addr)
        let address6 = string(info.netmask6).flatMap { $0.contains("/") ? $0 : nil } ?? string(info.addr6)
        guard address != nil || address6 != nil else { return nil }

        let gateway = string(info.gateway_addr) ?? "127.0.0.1"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gateway)
        let includes = list(info.split_includes)
        let excludes = list(info.split_excludes)
        let dns = [info.dns.0, info.dns.1, info.dns.2].compactMap(string)
        let useRemoteDNS = profile.dnsMode == .remote && !dns.isEmpty

        if let address {
            let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [string(info.netmask) ?? "255.255.255.255"])
            var routes = includes.compactMap(ipv4Route)
            if routes.isEmpty {
                routes = [NEIPv4Route.default()]
            } else if useRemoteDNS {
                routes += dns.filter { !$0.contains(":") }
                    .map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
            }
            ipv4.includedRoutes = routes
            ipv4.excludedRoutes = excludes.compactMap(ipv4Route)
            settings.ipv4Settings = ipv4
        }
        if let address6, let (host, prefix) = splitPrefix(address6) {
            let ipv6 = NEIPv6Settings(addresses: [host], networkPrefixLengths: [NSNumber(value: prefix)])
            let routes = includes.compactMap(ipv6Route)
            ipv6.includedRoutes = routes.isEmpty ? [NEIPv6Route.default()] : routes
            ipv6.excludedRoutes = excludes.compactMap(ipv6Route)
            settings.ipv6Settings = ipv6
        }
        if useRemoteDNS {
            let dnsSettings = NEDNSSettings(servers: dns)
            let domains = (string(info.domain) ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            if !domains.isEmpty { dnsSettings.searchDomains = domains }
            let splitDNS = list(info.split_dns)
            dnsSettings.matchDomains = splitDNS.isEmpty ? [""] : splitDNS
            settings.dnsSettings = dnsSettings
        }
        if let pac = string(info.proxy_pac), let url = URL(string: pac) {
            let proxy = NEProxySettings()
            proxy.autoProxyConfigurationEnabled = true
            proxy.proxyAutoConfigurationURL = url
            settings.proxySettings = proxy
        }
        if info.mtu > 0 { settings.mtu = NSNumber(value: info.mtu) }

        let signature = [address ?? "", string(info.netmask) ?? "", address6 ?? "", dns.joined(separator: ","),
                         includes.joined(separator: ","), excludes.joined(separator: ","),
                         String(info.mtu)].joined(separator: "|")
        return (settings, signature)
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        string(UnsafePointer(pointer))
    }

    private func list(_ head: UnsafeMutablePointer<oc_split_include>?) -> [String] {
        var values: [String] = []
        var item = head
        while let current = item {
            if let route = string(current.pointee.route) { values.append(route) }
            item = current.pointee.next
        }
        return values
    }

    private func splitPrefix(_ value: String) -> (String, Int)? {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let host = parts.first, !host.isEmpty else { return nil }
        if parts.count == 1 { return (host, host.contains(":") ? 128 : 32) }
        guard let prefix = Int(parts[1]) else { return nil }
        return (host, prefix)
    }

    private func ipv4Route(_ value: String) -> NEIPv4Route? {
        guard !value.contains(":") else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard let host = parts.first else { return nil }
        if parts.count == 2, parts[1].contains(".") {
            return NEIPv4Route(destinationAddress: host, subnetMask: parts[1])
        }
        let prefix = parts.count == 2 ? Int(parts[1]) ?? 32 : 32
        guard (0...32).contains(prefix) else { return nil }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - UInt32(prefix))
        let text = [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xff) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: host, subnetMask: text)
    }

    private func ipv6Route(_ value: String) -> NEIPv6Route? {
        guard value.contains(":"), let (host, prefix) = splitPrefix(value) else { return nil }
        return NEIPv6Route(destinationAddress: host, networkPrefixLength: NSNumber(value: prefix))
    }

    private func errorText(_ code: Int32) -> String {
        String(cString: strerror(-code))
    }
}
