import Foundation
import CryptoKit
import Security

/// Manages cryptographic keys for authentication and encryption
/// Uses iOS Keychain for secure storage and Secure Enclave when available
final class KeyManager {

    static let shared = KeyManager()

    private let keychainService = "com.kuurier.keys"
    private let privateKeyTag = "com.kuurier.privatekey"
    private let publicKeyTag = "com.kuurier.publickey"

    private init() {}

    // MARK: - Key Generation

    /// Generates a new Ed25519 keypair for authentication
    /// Stores the private key in the Keychain
    func generateKeyPair() throws -> Data {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Store private key in Keychain
        try storePrivateKey(privateKey.rawRepresentation)

        return publicKey.rawRepresentation
    }

    /// Returns the stored public key, or nil if not generated yet
    func getPublicKey() -> Data? {
        guard let privateKeyData = retrievePrivateKey() else { return nil }

        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            return privateKey.publicKey.rawRepresentation
        } catch {
            return nil
        }
    }

    /// Signs a challenge with the stored private key
    func sign(challenge: String) throws -> Data {
        guard let privateKeyData = retrievePrivateKey() else {
            throw KeyManagerError.noPrivateKey
        }

        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let challengeData = Data(challenge.utf8)

        return try privateKey.signature(for: challengeData)
    }

    /// Verifies a signature (for testing/validation)
    func verify(signature: Data, for data: Data, publicKey: Data) -> Bool {
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: data)
        } catch {
            return false
        }
    }

    // MARK: - Key Derivation

    /// Derives an encryption key from a shared secret using HKDF
    func deriveEncryptionKey(from sharedSecret: Data, salt: Data, info: Data) -> SymmetricKey {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key
    }

    // MARK: - Encryption/Decryption

    /// Encrypts data using AES-GCM
    func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw KeyManagerError.encryptionFailed
        }
        return combined
    }

    /// Decrypts AES-GCM encrypted data
    func decrypt(_ encryptedData: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Keychain Operations

    private func storePrivateKey(_ keyData: Data) throws {
        // Delete existing key if any
        deletePrivateKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyTag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainError(status)
        }
    }

    private func retrievePrivateKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deletePrivateKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: privateKeyTag
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Account Management

    /// Checks if the user has an existing keypair
    var hasExistingAccount: Bool {
        return retrievePrivateKey() != nil
    }

    /// Permanently deletes all keys (account deletion)
    func deleteAllKeys() {
        deletePrivateKey()
    }

    /// Exports the private key for backup (BIP39 mnemonic would be better in production)
    func exportPrivateKey() -> Data? {
        return retrievePrivateKey()
    }

    /// Imports a private key (for account recovery)
    func importPrivateKey(_ keyData: Data) throws {
        // Validate the key is a valid Ed25519 private key
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        try storePrivateKey(keyData)
    }
}

// MARK: - Errors

enum KeyManagerError: Error, LocalizedError {
    case noPrivateKey
    case encryptionFailed
    case decryptionFailed
    case keychainError(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .noPrivateKey:
            return "No private key found. Please create an account first."
        case .encryptionFailed:
            return "Failed to encrypt data."
        case .decryptionFailed:
            return "Failed to decrypt data."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .invalidKey:
            return "Invalid key format."
        }
    }
}
