import Foundation

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var server: String
    var username: String
    var protocolName: String = "anyconnect"
    var authGroup: String = ""
    var dnsMode: DNSMode = .remote
    var autoReconnect: Bool = true
    /// Accept the server certificate even when it fails validation.
    var ignoreCertificateErrors: Bool = false

    init(id: UUID = UUID(), name: String, server: String, username: String) {
        self.id = id
        self.name = name
        self.server = server
        self.username = username
    }

    enum CodingKeys: String, CodingKey {
        case id, name, server, username, protocolName, authGroup, dnsMode, autoReconnect, ignoreCertificateErrors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        server = try values.decode(String.self, forKey: .server)
        username = try values.decode(String.self, forKey: .username)
        protocolName = try values.decodeIfPresent(String.self, forKey: .protocolName) ?? "anyconnect"
        authGroup = try values.decodeIfPresent(String.self, forKey: .authGroup) ?? ""
        dnsMode = try values.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? .remote
        autoReconnect = try values.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        ignoreCertificateErrors = try values.decodeIfPresent(Bool.self, forKey: .ignoreCertificateErrors) ?? false
    }
}

enum DNSMode: String, Codable, CaseIterable, Identifiable {
    case remote, local

    var id: String { rawValue }
    var title: String { self == .remote ? "远程 VPN DNS" : "本地 DNS" }
}

enum VPNProtocol: String, CaseIterable, Identifiable {
    case anyconnect, gp, pulse, nc, f5, fortinet, array

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyconnect: "Cisco AnyConnect"
        case .gp: "GlobalProtect"
        case .pulse: "Pulse / Ivanti"
        case .nc: "Juniper Network Connect"
        case .f5: "F5 Big-IP"
        case .fortinet: "Fortinet"
        case .array: "Array Networks"
        }
    }
}
