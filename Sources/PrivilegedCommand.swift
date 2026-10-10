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

    private let restartLock = NSLock()
    private var helperIsCurrent = false

    /// An app update replaces the helper binary in the bundle, but launchd keeps the
    /// previous helper process running until it exits. Ask an outdated helper to exit
    /// while no VPN is up so the next request starts the new binary.
    func restartOutdatedHelper() {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard !helperIsCurrent, service.status == .enabled else { return }
        let expected = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        switch send(timeout: 5, { helper, reply in helper.helperVersion(reply: reply) }) {
        case .success(let version) where version == expected:
            helperIsCurrent = true
        case .success:
            guard case .success(true) = send(timeout: 10, { helper, reply in helper.restartIfIdle(reply: reply) })
            else { return }
            // The helper exits shortly after replying and refuses requests until then.
            Thread.sleep(forTimeInterval: 1)
            helperIsCurrent = true
        case .failure:
            // Helpers from 0.1.0 cannot answer or exit on request. Re-registering would
            // stop them but sends the daemon back to System Settings for approval, so
            // keep the old one: it serves every request this app makes until the next boot.
            helperIsCurrent = true
        }
    }

    private func call(_ invoke: (OpenConnectHelperProtocol, @escaping (Int32, String) -> Void) -> Void)
        -> (status: Int32, output: String) {
        restartOutdatedHelper()
        do { try ensureRegistered() }
        catch { return (-1, error.localizedDescription) }

        switch send(timeout: 120, { helper, reply in invoke(helper) { reply(($0, $1)) } }) {
        case .success(let (status, message)): return (status, HelperMessage.localized(message))
        case .failure(let error): return (-1, error.localizedDescription)
        }
    }

    private func send<Reply>(timeout: TimeInterval,
                             _ invoke: (OpenConnectHelperProtocol, @escaping (Reply) -> Void) -> Void)
        -> Result<Reply, NSError> {
        func failure(_ message: String) -> NSError {
            NSError(domain: "OpenConnectGUI", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let connection = NSXPCConnection(machServiceName: HelperService.name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OpenConnectHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Reply, NSError> = .failure(failure(String(localized: "The privileged helper did not respond.")))
        let finish: (Result<Reply, NSError>) -> Void = { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(failure(String(localized: "Could not connect to the privileged helper: \(error.localizedDescription)"))))
        }) as? OpenConnectHelperProtocol else {
            return .failure(failure(String(localized: "Could not create a connection to the privileged helper.")))
        }
        invoke(proxy) { finish(.success($0)) }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return .failure(failure(String(localized: "Timed out waiting for the privileged helper.")))
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
