import Foundation
import CryptoKit
import Security

/// Stores Signal Protocol keys in the iOS Keychain
/// This provides the persistence layer for Signal Protocol operations
final class SignalStore {

    static let shared = SignalStore()

    private let keychainService = "com.kuurier.signal"

    // Key tags for different key types
    private let identityKeyTag = "signal.identity"
    private let signedPreKeyTag = "signal.signedprekey"
    private let preKeyPrefix = "signal.prekey."
    private let registrationIdTag = "signal.registrationid"

    private init() {}

    // MARK: - Registration ID

    /// Gets or creates a registration ID (random 14-bit integer)
    var registrationId: Int {
        get {
            if let data = getData(forKey: registrationIdTag),
               data.count >= 4 {
                return Int(data.withUnsafeBytes { $0.load(as: UInt32.self) }) & 0x3FFF
            }
            // Generate new registration ID
            let newId = Int.random(in: 1...0x3FFF)
            var idValue = UInt32(newId)
            let idData = Data(bytes: &idValue, count: 4)
            try? setData(idData, forKey: registrationIdTag)
            return newId
        }
    }

    // MARK: - Identity Key Pair

    /// Generates and stores a new identity key pair
    /// Returns the public key
    @discardableResult
    func generateIdentityKeyPair() throws -> Data {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        try setData(privateKey.rawRepresentation, forKey: identityKeyTag)
        return privateKey.publicKey.rawRepresentation
    }

    /// Gets the identity private key
    func getIdentityPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        guard let data = getData(forKey: identityKeyTag) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Gets the identity public key
    func getIdentityPublicKey() -> Data? {
        return getIdentityPrivateKey()?.publicKey.rawRepresentation
    }

    /// Checks if identity key exists
    var hasIdentityKey: Bool {
        return getData(forKey: identityKeyTag) != nil
    }

    // MARK: - Signed Pre-Key

    /// Signed pre-key with its metadata
    struct SignedPreKey {
        let keyId: Int
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let signature: Data
        let timestamp: Date

        var publicKey: Data {
            privateKey.publicKey.rawRepresentation
        }
    }

    /// Generates a new signed pre-key
    /// The signature is created using Ed25519 (identity signing key)
    func generateSignedPreKey(keyId: Int, signingKey: Curve25519.Signing.PrivateKey) throws -> SignedPreKey {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation

        // Sign the public key with the identity signing key
        let signature = try signingKey.signature(for: publicKey)

        let signedPreKey = SignedPreKey(
            keyId: keyId,
            privateKey: privateKey,
            signature: signature,
            timestamp: Date()
        )

        // Store the signed pre-key
        try storeSignedPreKey(signedPreKey)

        return signedPreKey
    }

    private func storeSignedPreKey(_ spk: SignedPreKey) throws {
        // Store: keyId (4 bytes) + timestamp (8 bytes) + signature (64 bytes) + privateKey (32 bytes)
        var data = Data()

        var keyId = UInt32(spk.keyId)
        data.append(Data(bytes: &keyId, count: 4))

        var timestamp = spk.timestamp.timeIntervalSince1970
        data.append(Data(bytes: &timestamp, count: 8))

        data.append(spk.signature)
        data.append(spk.privateKey.rawRepresentation)

        try setData(data, forKey: signedPreKeyTag)
    }

    /// Gets the current signed pre-key
    func getSignedPreKey() -> SignedPreKey? {
        guard let data = getData(forKey: signedPreKeyTag),
              data.count >= 108 else { return nil } // 4 + 8 + 64 + 32 = 108

        let keyId = Int(data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
        let timestamp = data.dropFirst(4).prefix(8).withUnsafeBytes { $0.load(as: Double.self) }
        let signature = data.dropFirst(12).prefix(64)
        let privateKeyData = data.dropFirst(76).prefix(32)

        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }

        return SignedPreKey(
            keyId: keyId,
            privateKey: privateKey,
            signature: Data(signature),
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    // MARK: - One-Time Pre-Keys

    /// Pre-key with its ID
    struct PreKey {
        let keyId: Int
        let privateKey: Curve25519.KeyAgreement.PrivateKey

        var publicKey: Data {
            privateKey.publicKey.rawRepresentation
        }
    }

    /// Generates a batch of one-time pre-keys
    func generatePreKeys(startId: Int, count: Int) throws -> [PreKey] {
        var preKeys: [PreKey] = []

        for i in 0..<count {
            let keyId = startId + i
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let preKey = PreKey(keyId: keyId, privateKey: privateKey)

            // Store each pre-key
            try setData(privateKey.rawRepresentation, forKey: preKeyPrefix + String(keyId))
            preKeys.append(preKey)
        }

        // Update the next pre-key ID counter
        var nextId = UInt32(startId + count)
        try? setData(Data(bytes: &nextId, count: 4), forKey: "signal.nextprekeyid")

        return preKeys
    }

    /// Gets the next pre-key ID to use
    var nextPreKeyId: Int {
        if let data = getData(forKey: "signal.nextprekeyid"),
           data.count >= 4 {
            return Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
        }
        return 1
    }

    /// Gets a pre-key by ID
    func getPreKey(id: Int) -> PreKey? {
        guard let data = getData(forKey: preKeyPrefix + String(id)),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return PreKey(keyId: id, privateKey: privateKey)
    }

    /// Removes a consumed pre-key
    func removePreKey(id: Int) {
        delete(key: preKeyPrefix + String(id))
    }

    /// Counts stored pre-keys (approximate - scans common range)
    func countPreKeys() -> Int {
        var count = 0
        for i in 0..<1000 {
            if getData(forKey: preKeyPrefix + String(nextPreKeyId - 1000 + i)) != nil {
                count += 1
            }
        }
        return count
    }

    // MARK: - Keychain Operations

    private func setData(_ data: Data, forKey key: String) throws {
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SignalStoreError.keychainError(status)
        }
    }

    private func getData(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Deletes all Signal keys (for account deletion/reset)
    func deleteAllSignalKeys() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Double Ratchet Session Storage

    private let sessionPrefix = "signal.session."

    /// Stores a Double Ratchet session state
    func storeSession(_ state: DoubleRatchet.SessionState, for recipientId: String) throws {
        let data = try DoubleRatchet.serializeState(state)
        try setData(data, forKey: sessionPrefix + recipientId)
    }

    /// Retrieves a Double Ratchet session state
    func getSession(for recipientId: String) -> DoubleRatchet.SessionState? {
        guard let data = getData(forKey: sessionPrefix + recipientId) else {
            return nil
        }
        return try? DoubleRatchet.deserializeState(data)
    }

    /// Deletes a session with a specific user
    func deleteSession(for recipientId: String) {
        delete(key: sessionPrefix + recipientId)
    }

    /// Checks if a session exists with a user
    func hasSession(with recipientId: String) -> Bool {
        return getData(forKey: sessionPrefix + recipientId) != nil
    }

    /// Lists all session user IDs
    func listSessionIds() -> [String] {
        // This is a simplified implementation
        // In production, you might want to track session IDs separately
        return []
    }
}

// MARK: - Errors

enum SignalStoreError: Error, LocalizedError {
    case keychainError(OSStatus)
    case noIdentityKey
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .noIdentityKey:
            return "No identity key found"
        case .invalidKey:
            return "Invalid key format"
        }
    }
}
