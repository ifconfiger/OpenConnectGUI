import Foundation
import Network

struct PhysicalNetworkState: Equatable {
    let available: Bool
    let signature: String?
}

final class NetworkPathObserver {
    var onChange: (@MainActor (PhysicalNetworkState) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "xyz.nows.openconnect.network-path")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = Set(path.availableInterfaces.compactMap { interface -> String? in
                switch interface.type {
                case .wifi, .wiredEthernet, .cellular:
                    return interface.name
                case .other where interface.name.hasPrefix("en"):
                    return interface.name
                default:
                    return nil
                }
            }).sorted()
            let available = path.status == .satisfied && !interfaces.isEmpty
            let gateways = path.gateways.map(String.init(describing:)).sorted()
            let state = PhysicalNetworkState(available: available,
                                             signature: available ? (interfaces + gateways).joined(separator: "|") : nil)
            Task { @MainActor in self?.onChange?(state) }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
