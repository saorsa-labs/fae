import Foundation
import Security

/// Manages secure credential storage via macOS Keychain.
///
/// Replaces: `src/credentials/` (1,640 lines)
enum CredentialManager {
    private static let service = "com.saorsalabs.fae"

    /// Store a credential in the Keychain.
    static func store(key: String, value: String) throws {
        let data = Data(value.utf8)

        // Delete existing entry first.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.storeFailed(key, status)
        }
    }

    /// Retrieve a credential from the Keychain.
    static func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Delete a credential from the Keychain.
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum CredentialError: LocalizedError {
        case storeFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .storeFailed(let key, let status):
                return "Failed to store credential '\(key)': OSStatus \(status)"
            }
        }
    }
}
