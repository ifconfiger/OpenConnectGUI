import Foundation
import ServiceManagement

final class PrivilegedCommand {
    static let shared = PrivilegedCommand()
    private init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: HelperService.plist) }

    func prepare() -> String? {
        do { try ensureRegistered(); return nil }
        catch { return error.localizedDescription }
    }

    func connect(_ profile: VPNProfile, password: String) -> (status: Int32, output: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return (-1, "无法编码 VPN 配置。") }
        return call { helper, reply in helper.connect(data, password: password, reply: reply) }
    }

    func disconnect(_ profile: VPNProfile) -> (status: Int32, output: String) {
        call { helper, reply in helper.disconnect(profile.id.uuidString, reply: reply) }
    }

    func cleanup(_ profile: VPNProfile) -> (status: Int32, output: String) {
        call { helper, reply in helper.cleanup(profile.id.uuidString, reply: reply) }
    }

    func refreshNetwork(_ profile: VPNProfile) -> (status: Int32, output: String) {
        call { helper, reply in helper.refreshNetwork(profile.id.uuidString, reply: reply) }
    }

    private func ensureRegistered() throws {
        switch service.status {
        case .enabled: return
        case .notRegistered, .notFound:
            do { try service.register() }
            catch {
                if service.status != .requiresApproval { throw error }
            }
            if service.status == .enabled { return }
            fallthrough
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw NSError(domain: "OpenConnectGUI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "请在系统设置 → 通用 → 登录项与扩展中批准 OpenConnectGUI 后重试连接。"])
        @unknown default:
            throw NSError(domain: "OpenConnectGUI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "特权辅助服务状态未知，请检查系统设置中的登录项。"])
        }
    }

    private func call(_ invoke: (OpenConnectHelperProtocol, @escaping (Int32, String) -> Void) -> Void)
        -> (status: Int32, output: String) {
        do { try ensureRegistered() }
        catch { return (-1, error.localizedDescription) }

        let connection = NSXPCConnection(machServiceName: HelperService.name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OpenConnectHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: (Int32, String) = (-1, "特权辅助服务没有响应。")
        let finish: (Int32, String) -> Void = { status, message in
            lock.lock()
            result = (status, message)
            lock.unlock()
            semaphore.signal()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(-1, "无法连接特权辅助服务：\(error.localizedDescription)")
        }) as? OpenConnectHelperProtocol else { return (-1, "无法创建特权辅助服务连接。") }
        invoke(proxy, finish)
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            return (-1, "等待特权辅助服务超时。")
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
