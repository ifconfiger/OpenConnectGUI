import Foundation
import NetworkExtension
import CryptoKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = TunnelLog()
    private var tunnel: OpenConnectTunnel?
    private var pathObservation: NSKeyValueObservation?
    private var lastPath: NWPath?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              let encodedProfile = configuration.providerConfiguration?["profile"] as? Data,
              let profile = try? JSONDecoder().decode(VPNProfile.self, from: encodedProfile) else {
            completionHandler(failure(2, "VPN 配置无效，请在 App 中重新保存连接。"))
            return
        }
        // Starts from the app pass the password; on-demand and system starts
        // read it from the keychain shared with the app.
        let password = (options?["password"] as? String)
            ?? (try? KeychainStore.password(for: profile.id)) ?? nil
        guard let password, !password.isEmpty else {
            completionHandler(failure(3, "未找到保存的 VPN 密码，请在 App 中保存密码后连接。"))
            return
        }

        // Never retry credentials the gateway already rejected unless the user
        // starts the connection again from the app; this avoids account lockouts
        // from automatic reconnects.
        let fingerprint = AuthFailureGuard.fingerprint(profile, password: password)
        if options?["manual"] != nil {
            AuthFailureGuard.clear(profile.id)
        } else if AuthFailureGuard.hasFailed(profile.id, fingerprint: fingerprint) {
            completionHandler(failure(4, "保存的账号或密码上次被服务器拒绝，请在 App 中更新后重新连接。"))
            return
        }

        let tunnel = OpenConnectTunnel(provider: self, profile: profile, password: password, log: log)
        tunnel.onAuthenticationFailure = { AuthFailureGuard.record(profile.id, fingerprint: fingerprint) }
        self.tunnel = tunnel
        lastPath = defaultPath
        pathObservation = observe(\.defaultPath, options: [.new]) { [weak self] provider, _ in
            self?.defaultPathChanged(provider.defaultPath)
        }
        tunnel.start(completion: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        pathObservation = nil
        log.append("正在断开连接。")
        guard let tunnel else { completionHandler(); return }
        tunnel.stop(completion: completionHandler)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data(log.text.utf8))
    }

    private func defaultPathChanged(_ path: NWPath?) {
        let previous = lastPath
        lastPath = path
        guard let path else { return }
        if let previous, path.isEqual(to: previous) { return }
        tunnel?.networkChanged(available: path.status == .satisfied)
    }

    private func failure(_ code: Int, _ message: String) -> NSError {
        log.append(message, error: true)
        return NSError(domain: "xyz.nows.openconnect.tunnel", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Remembers, per profile, a hash of credentials the server rejected.
private enum AuthFailureGuard {
    private static let defaults = UserDefaults.standard

    static func fingerprint(_ profile: VPNProfile, password: String) -> String {
        let material = [profile.server, profile.protocolName, profile.username, profile.authGroup, password]
            .joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hasFailed(_ id: UUID, fingerprint: String) -> Bool {
        defaults.string(forKey: key(id)) == fingerprint
    }

    static func record(_ id: UUID, fingerprint: String) {
        defaults.set(fingerprint, forKey: key(id))
    }

    static func clear(_ id: UUID) {
        defaults.removeObject(forKey: key(id))
    }

    private static func key(_ id: UUID) -> String { "authFailure." + id.uuidString }
}
