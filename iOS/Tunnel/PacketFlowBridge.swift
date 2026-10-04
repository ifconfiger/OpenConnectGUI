import Foundation
import NetworkExtension
import Darwin

/// Adapts Network Extension's packet API to the datagram file descriptor
/// accepted by libopenconnect's openconnect_setup_tun_fd(). On Apple platforms
/// that descriptor carries a four-byte address-family prefix in network order.
/// A new descriptor is handed out for every OpenConnect session while the
/// single NEPacketTunnelFlow reader keeps running across reconnects.
final class PacketFlowBridge {
    private let flow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "xyz.nows.openconnect.packet-flow")
    private let lock = NSLock()
    private var active = false
    private var packetFileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    /// Returns the descriptor for libopenconnect, which takes ownership of it.
    func makeTunnelDescriptor() throws -> Int32 {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        for descriptor in descriptors {
            var size: Int32 = 512 * 1024
            setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let packetDescriptor = descriptors[1]
        _ = fcntl(packetDescriptor, F_SETFL, fcntl(packetDescriptor, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: packetDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromOpenConnect(packetDescriptor) }
        source.setCancelHandler { close(packetDescriptor) }

        lock.lock()
        let previous = readSource
        readSource = source
        packetFileDescriptor = packetDescriptor
        let startReading = !active
        active = true
        lock.unlock()

        previous?.cancel()
        source.resume()
        if startReading { readFromPacketFlow() }
        return descriptors[0]
    }

    func stop() {
        lock.lock()
        active = false
        let source = readSource
        readSource = nil
        packetFileDescriptor = -1
        lock.unlock()
        source?.cancel()
    }

    private func currentDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return active ? packetFileDescriptor : nil
    }

    private func readFromPacketFlow() {
        flow.readPackets { [weak self] packets, protocols in
            guard let self, let descriptor = self.currentDescriptor() else { return }
            for (packet, protocolNumber) in zip(packets, protocols) {
                let family = protocolNumber.int32Value
                guard family == AF_INET || family == AF_INET6 else { continue }
                var header = UInt32(family).bigEndian
                var frame = Data(bytes: &header, count: MemoryLayout<UInt32>.size)
                frame.append(packet)
                frame.withUnsafeBytes { bytes in
                    guard let address = bytes.baseAddress else { return }
                    _ = send(descriptor, address, bytes.count, MSG_DONTWAIT)
                }
            }
            self.readFromPacketFlow()
        }
    }

    private func readFromOpenConnect(_ descriptor: Int32) {
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        var buffer = [UInt8](repeating: 0, count: 65_540)
        while packets.count < 64 {
            let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            guard count > MemoryLayout<UInt32>.size else { continue }
            let family = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { continue }
            packets.append(Data(buffer[4..<count]))
            protocols.append(NSNumber(value: family))
        }
        if !packets.isEmpty { flow.writePackets(packets, withProtocols: protocols) }
    }
}
