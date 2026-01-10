import Foundation
import Security

/// Secure local storage using iOS Keychain
/// All sensitive data is stored encrypted in the Keychain
final class SecureStorage {

    static let shared = SecureStorage()

    private let service = "com.kuurier.storage"

    private init() {}

    // MARK: - Token Storage

    private let authTokenKey = "auth_token"
    private let userIDKey = "user_id"

    var authToken: String? {
        get { getString(forKey: authTokenKey) }
        set {
            if let value = newValue {
                try? setString(value, forKey: authTokenKey)
            } else {
                delete(key: authTokenKey)
            }
        }
    }

    var userID: String? {
        get { getString(forKey: userIDKey) }
        set {
            if let value = newValue {
                try? setString(value, forKey: userIDKey)
            } else {
                delete(key: userIDKey)
            }
        }
    }

    var isLoggedIn: Bool {
        return authToken != nil && userID != nil
    }

    // MARK: - Generic Operations

    func setString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStorageError.encodingFailed
        }
        try setData(data, forKey: key)
    }

    func getString(forKey key: String) -> String? {
        guard let data = getData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, forKey key: String) throws {
        // Delete existing item first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.keychainError(status)
        }
    }

    func getData(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Account Management

    /// Clears all stored data (logout/account deletion)
    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Wipes all app data including keys (panic button)
    func panicWipe() {
        // Clear secure storage
        clearAll()

        // Clear keys
        KeyManager.shared.deleteAllKeys()

        // Clear any cached data
        URLCache.shared.removeAllCachedResponses()

        // Clear UserDefaults (non-sensitive settings)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}

// MARK: - Errors

enum SecureStorageError: Error, LocalizedError {
    case encodingFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}
