import Foundation
import Security

enum KeychainStore {
    private static let service = "xyz.nows.openconnect.password"

    static func password(for id: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(for: id).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return password
    }

    static func save(_ password: String, for id: UUID) throws {
        if password.isEmpty {
            try delete(for: id)
            return
        }
        // Replace rather than update so the item always lands in the default
        // access group, which on iOS is the group shared with the VPN extension.
        try delete(for: id)
        let status = SecItemAdd(query(for: id).merging([
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func delete(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func query(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Keychain operation failed (\(status))")])
    }
}
