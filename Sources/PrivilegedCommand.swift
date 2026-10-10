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
        guard let data = try? JSONEncoder().encode(profile) else { return (-1, String(localized: "Failed to encode the VPN profile.")) }
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
                String(localized: "Approve OpenConnectGUI in System Settings → General → Login Items & Extensions, then connect again.")])
        @unknown default:
            throw NSError(domain: "OpenConnectGUI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The privileged helper is in an unknown state. Check Login Items in System Settings.")])
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
        var result: (Int32, String) = (-1, String(localized: "The privileged helper did not respond."))
        let finish: (Int32, String) -> Void = { status, message in
            lock.lock()
            result = (status, message)
            lock.unlock()
            semaphore.signal()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(-1, String(localized: "Could not connect to the privileged helper: \(error.localizedDescription)"))
        }) as? OpenConnectHelperProtocol else { return (-1, String(localized: "Could not create a connection to the privileged helper.")) }
        invoke(proxy) { status, message in finish(status, HelperMessage.localized(message)) }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            return (-1, String(localized: "Timed out waiting for the privileged helper."))
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
