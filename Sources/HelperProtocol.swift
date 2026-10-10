import Foundation

enum HelperService {
    static let name = "xyz.nows.openconnect.privileged"
    static let plist = name + ".plist"
}

@objc protocol OpenConnectHelperProtocol {
    func connect(_ profileData: Data, password: String,
                 reply: @escaping (Int32, String) -> Void)
    func disconnect(_ profileID: String, reply: @escaping (Int32, String) -> Void)
    func cleanup(_ profileID: String, reply: @escaping (Int32, String) -> Void)
    func refreshNetwork(_ profileID: String, reply: @escaping (Int32, String) -> Void)
}

/// The helper runs as root without the user's language preferences, so it replies in
/// English and the app translates each reply against its own string catalog.
enum HelperMessage {
    static let cleanupFailedPrefix = "Failed to clean up leftover VPN network settings: "

    static func localized(_ message: String) -> String {
        if message.hasPrefix(cleanupFailedPrefix) {
            let detail = String(message.dropFirst(cleanupFailedPrefix.count))
            return String(localized: "Failed to clean up leftover VPN network settings: \(detail)")
        }
        return Bundle.main.localizedString(forKey: message, value: message, table: nil)
    }
}
