import Foundation
import NetworkExtension
import Darwin

/// Adapts Network Extension's packet API to the datagram file descriptor
/// accepted by libopenconnect's openconnect_setup_tun_fd(). On Apple platforms
/// that descriptor carries a four-byte address-family prefix in network order.
final class PacketFlowBridge {
    let openConnectFileDescriptor: Int32

    private let flow: NEPacketTunnelFlow
    private let packetFileDescriptor: Int32
    private let queue = DispatchQueue(label: "xyz.nows.openconnect.packet-flow")
    private let lock = NSLock()
    private var active = false
    private var readSource: DispatchSourceRead?

    init(flow: NEPacketTunnelFlow) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.flow = flow
        openConnectFileDescriptor = descriptors[0]
        packetFileDescriptor = descriptors[1]
    }

    func start() {
        lock.lock()
        guard !active else { lock.unlock(); return }
        active = true
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: packetFileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromOpenConnect() }
        source.setCancelHandler { [packetFileDescriptor] in close(packetFileDescriptor) }
        readSource = source
        source.resume()
        readFromPacketFlow()
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        readSource?.cancel()
        readSource = nil
    }

    private func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func readFromPacketFlow() {
        guard isActive() else { return }
        flow.readPackets { [weak self] packets, protocols in
            guard let self, self.isActive() else { return }
            for (packet, protocolNumber) in zip(packets, protocols) {
                let family = protocolNumber.int32Value
                guard family == AF_INET || family == AF_INET6 else { continue }
                var header = UInt32(family).bigEndian
                var frame = Data(bytes: &header, count: MemoryLayout<UInt32>.size)
                frame.append(packet)
                frame.withUnsafeBytes { bytes in
                    guard let address = bytes.baseAddress else { return }
                    _ = send(self.packetFileDescriptor, address, bytes.count, MSG_DONTWAIT)
                }
            }
            self.readFromPacketFlow()
        }
    }

    private func readFromOpenConnect() {
        guard isActive() else { return }
        var buffer = [UInt8](repeating: 0, count: 65_540)
        let count = recv(packetFileDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
        guard count > MemoryLayout<UInt32>.size else { return }
        let family = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { return }
        flow.writePackets([Data(buffer[4..<count])], withProtocols: [NSNumber(value: family)])
    }
}
