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
    var proxyEnabled: Bool = false
    var proxyURL: String = ""
    /// Accept the server certificate even when it fails validation.
    var ignoreCertificateErrors: Bool = false

    init(id: UUID = UUID(), name: String, server: String, username: String) {
        self.id = id
        self.name = name
        self.server = server
        self.username = username
    }

    enum CodingKeys: String, CodingKey {
        case id, name, server, username, protocolName, authGroup, dnsMode, autoReconnect, proxyEnabled, proxyURL, ignoreCertificateErrors
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
        proxyEnabled = try values.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        proxyURL = try values.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
        ignoreCertificateErrors = try values.decodeIfPresent(Bool.self, forKey: .ignoreCertificateErrors) ?? false
    }

    var hasValidProxy: Bool {
        if !proxyEnabled { return true }
        if proxyURL.isEmpty { return false }
        guard proxyURL.utf8.count < 2048,
              let proxy = URLComponents(string: proxyURL),
              proxy.scheme == "http", proxy.host != nil, proxy.port != nil,
              proxy.user == nil, proxy.password == nil,
              (proxy.path.isEmpty || proxy.path == "/"),
              proxy.query == nil, proxy.fragment == nil else { return false }
        return true
    }
}

enum DNSMode: String, Codable, CaseIterable, Identifiable {
    case remote, local

    var id: String { rawValue }
    var title: String { self == .remote ? String(localized: "Remote VPN DNS") : String(localized: "Local DNS") }
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
