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
    /// The app build (`CFBundleVersion`) the running helper was launched from.
    func helperVersion(reply: @escaping (String) -> Void)
    /// Exit so launchd starts the replaced binary on the next request. Refused while
    /// a request is in flight or any OpenConnect session started by the helper is alive.
    func restartIfIdle(reply: @escaping (Bool) -> Void)
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
