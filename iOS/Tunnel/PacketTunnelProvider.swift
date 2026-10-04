import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
              let encodedProfile = configuration.providerConfiguration?["profile"] as? Data,
              (try? JSONDecoder().decode(VPNProfile.self, from: encodedProfile)) != nil,
              let password = options?["password"] as? NSString,
              !password.isEqual(to: "") else {
            completionHandler(NSError(domain: "xyz.nows.openconnect.tunnel", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "VPN 配置或密码无效。"]))
            return
        }
        // PacketFlowBridge bridges NEPacketTunnelFlow to the datagram FD
        // accepted by openconnect_setup_tun_fd(). The iOS libopenconnect build,
        // authentication callbacks and network-settings callback are pending.
        completionHandler(NSError(domain: "xyz.nows.openconnect.tunnel", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "iOS OpenConnect 协议核心尚未接入，VPN 无法建立。"]))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
