import Foundation
import Combine
import CryptoKit

/// Service for managing Sender Keys for group encryption
/// Uses a simplified Sender Key scheme based on AES-GCM with key derivation
final class SenderKeyService: ObservableObject {

    static let shared = SenderKeyService()

    // MARK: - Published State

    @Published var isInitialized = false

    // MARK: - Private Properties

    private let api = APIClient.shared
    private let secureStorage = SecureStorage.shared

    // Local cache of sender keys: channelId -> (userId -> SenderKey)
    private var senderKeyCache: [String: [String: SenderKeyData]] = [:]

    // Our sender keys: channelId -> OwnSenderKey
    private var ownSenderKeys: [String: OwnSenderKey] = [:]

    private init() {}

    // MARK: - Sender Key Types

    struct SenderKeyData {
        let distributionId: String
        let chainKey: SymmetricKey
        var iteration: Int
    }

    struct OwnSenderKey {
        let distributionId: String
        let chainKey: SymmetricKey
        var iteration: Int
    }

    // MARK: - Key Generation

    /// Generates a new sender key for a channel
    func generateSenderKey(for channelId: String) async throws -> OwnSenderKey {
        // Generate new random chain key
        let chainKey = SymmetricKey(size: .bits256)
        let distributionId = UUID().uuidString

        let senderKey = OwnSenderKey(
            distributionId: distributionId,
            chainKey: chainKey,
            iteration: 0
        )

        // Store locally
        ownSenderKeys[channelId] = senderKey

        // Upload to server
        try await uploadSenderKey(for: channelId, senderKey: senderKey)

        return senderKey
    }

    /// Gets or creates our sender key for a channel
    func getOrCreateSenderKey(for channelId: String) async throws -> OwnSenderKey {
        // Check local cache first
        if let existing = ownSenderKeys[channelId] {
            return existing
        }

        // Generate new key
        return try await generateSenderKey(for: channelId)
    }

    // MARK: - Key Distribution

    /// Uploads our sender key to the server
    private func uploadSenderKey(for channelId: String, senderKey: OwnSenderKey) async throws {
        let keyData = senderKey.chainKey.withUnsafeBytes { Data($0) }

        let request = UploadSenderKeyRequest(
            channelId: channelId,
            distributionId: senderKey.distributionId,
            senderKey: keyData.base64EncodedString()
        )

        let _: MessageResponse = try await api.post("/groups/sender-key", body: request)
    }

    /// Fetches all sender keys for a channel
    func fetchSenderKeys(for channelId: String) async throws {
        let response: SenderKeysResponse = try await api.get("/groups/\(channelId)/sender-keys")

        var channelKeys: [String: SenderKeyData] = [:]
        for key in response.senderKeys {
            if let keyData = Data(base64Encoded: key.senderKey) {
                let chainKey = SymmetricKey(data: keyData)
                channelKeys[key.userId] = SenderKeyData(
                    distributionId: key.distributionId,
                    chainKey: chainKey,
                    iteration: key.iteration
                )
            }
        }

        senderKeyCache[channelId] = channelKeys
    }

    /// Gets a sender key for a specific user in a channel
    func getSenderKey(for userId: String, in channelId: String) async throws -> SenderKeyData? {
        // Check cache first
        if let cachedKeys = senderKeyCache[channelId],
           let userKey = cachedKeys[userId] {
            return userKey
        }

        // Fetch from server
        try await fetchSenderKeys(for: channelId)

        return senderKeyCache[channelId]?[userId]
    }

    // MARK: - Encryption

    /// Encrypts a message for a group channel using Sender Keys
    func encryptForGroup(_ plaintext: Data, channelId: String) async throws -> GroupCiphertext {
        // Get or create our sender key
        let senderKey = try await getOrCreateSenderKey(for: channelId)

        // Derive message key from chain key using HKDF
        let messageKey = deriveMessageKey(from: senderKey.chainKey, iteration: senderKey.iteration)

        // Encrypt with AES-GCM
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: messageKey, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw SenderKeyError.encryptionFailed
        }

        // Increment iteration
        ownSenderKeys[channelId]?.iteration += 1

        return GroupCiphertext(
            distributionId: senderKey.distributionId,
            iteration: senderKey.iteration,
            ciphertext: combined
        )
    }

    /// Decrypts a group message using the sender's key
    func decryptFromGroup(_ ciphertext: GroupCiphertext, from senderId: String, channelId: String) async throws -> Data {
        // Get the sender's key
        guard let senderKey = try await getSenderKey(for: senderId, in: channelId) else {
            throw SenderKeyError.senderKeyNotFound
        }

        // Verify distribution ID matches
        guard senderKey.distributionId == ciphertext.distributionId else {
            throw SenderKeyError.invalidDistributionId
        }

        // Derive message key at the correct iteration
        let messageKey = deriveMessageKey(from: senderKey.chainKey, iteration: ciphertext.iteration)

        // Decrypt with AES-GCM
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext.ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: messageKey)

        return plaintext
    }

    // MARK: - Key Derivation

    private func deriveMessageKey(from chainKey: SymmetricKey, iteration: Int) -> SymmetricKey {
        let info = "SenderKey-\(iteration)".data(using: .utf8)!
        let salt = Data(repeating: 0, count: 32)

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: chainKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - Key Rotation

    /// Rotates our sender key for a channel (called when membership changes)
    func rotateSenderKey(for channelId: String) async throws {
        // Clear local key
        ownSenderKeys.removeValue(forKey: channelId)
        senderKeyCache.removeValue(forKey: channelId)

        // Generate and upload new key
        _ = try await generateSenderKey(for: channelId)
    }

    /// Clears cached keys for a channel (called when key rotation is detected)
    func clearChannelKeys(for channelId: String) {
        senderKeyCache.removeValue(forKey: channelId)
        ownSenderKeys.removeValue(forKey: channelId)
    }

    /// Clears all cached keys
    func clearAllKeys() {
        senderKeyCache.removeAll()
        ownSenderKeys.removeAll()
    }

    // MARK: - Key Status

    /// Checks if we have a sender key for a channel
    func hasSenderKey(for channelId: String) -> Bool {
        return ownSenderKeys[channelId] != nil
    }

    /// Gets key status for all members in a channel
    func getKeyStatus(for channelId: String) async throws -> [MemberKeyStatus] {
        let response: KeyStatusResponse = try await api.get("/groups/\(channelId)/key-status")
        return response.members
    }
}

// MARK: - Types

struct GroupCiphertext: Codable {
    let distributionId: String
    let iteration: Int
    let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case distributionId = "distribution_id"
        case iteration
        case ciphertext
    }
}

struct UploadSenderKeyRequest: Encodable {
    let channelId: String
    let distributionId: String
    let senderKey: String

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case distributionId = "distribution_id"
        case senderKey = "sender_key"
    }
}

struct SenderKeyResponse: Decodable {
    let channelId: String
    let userId: String
    let distributionId: String
    let senderKey: String
    let iteration: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case userId = "user_id"
        case distributionId = "distribution_id"
        case senderKey = "sender_key"
        case iteration
        case createdAt = "created_at"
    }
}

struct SenderKeysResponse: Decodable {
    let senderKeys: [SenderKeyResponse]

    enum CodingKeys: String, CodingKey {
        case senderKeys = "sender_keys"
    }
}

struct MemberKeyStatus: Decodable {
    let userId: String
    let hasKey: Bool
    let iteration: Int?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case hasKey = "has_key"
        case iteration
    }
}

struct KeyStatusResponse: Decodable {
    let members: [MemberKeyStatus]
}

enum SenderKeyError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case senderKeyNotFound
    case invalidDistributionId
    case keyRotationRequired

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt message"
        case .decryptionFailed:
            return "Failed to decrypt message"
        case .senderKeyNotFound:
            return "Sender key not found for user"
        case .invalidDistributionId:
            return "Invalid sender key distribution ID"
        case .keyRotationRequired:
            return "Key rotation required"
        }
    }
}
