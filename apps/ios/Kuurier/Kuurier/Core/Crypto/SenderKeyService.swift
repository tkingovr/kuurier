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
    private let signalService = SignalService.shared

    // Local cache of sender keys: channelId -> (userId -> SenderKey)
    private var senderKeyCache: [String: [String: SenderKeyData]] = [:]

    // Our sender keys: channelId -> OwnSenderKey
    private var ownSenderKeys: [String: OwnSenderKey] = [:]

    // SECURITY: Track seen iterations per sender per channel to prevent replay attacks
    // Format: channelId -> (userId -> Set of seen iterations)
    private var seenIterations: [String: [String: Set<Int>]] = [:]
    private let maxSeenIterationsPerSender = 1000 // Limit memory usage

    // Key for storing own sender keys in UserDefaults (encrypted data stored in Keychain)
    private let ownSenderKeysStorageKey = "com.kuurier.ownSenderKeys"

    private init() {
        // Load persisted sender keys on initialization
        loadPersistedSenderKeys()
    }

    // MARK: - Persistence

    /// Saves own sender keys to secure storage
    private func persistSenderKeys() {
        var keysToStore: [String: [String: Any]] = [:]

        for (channelId, key) in ownSenderKeys {
            let keyData = key.chainKey.withUnsafeBytes { Data($0) }
            keysToStore[channelId] = [
                "distributionId": key.distributionId,
                "chainKey": keyData.base64EncodedString(),
                "iteration": key.iteration
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: keysToStore) {
            // Store in Keychain via SecureStorage
            try? secureStorage.setData(jsonData, forKey: ownSenderKeysStorageKey)
        }
    }

    /// Loads sender keys from secure storage
    private func loadPersistedSenderKeys() {
        guard let jsonData = secureStorage.getData(forKey: ownSenderKeysStorageKey),
              let keysDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: [String: Any]] else {
            return
        }

        for (channelId, keyDict) in keysDict {
            guard let distributionId = keyDict["distributionId"] as? String,
                  let chainKeyBase64 = keyDict["chainKey"] as? String,
                  let chainKeyData = Data(base64Encoded: chainKeyBase64),
                  let iteration = keyDict["iteration"] as? Int else {
                continue
            }

            let chainKey = SymmetricKey(data: chainKeyData)
            ownSenderKeys[channelId] = OwnSenderKey(
                distributionId: distributionId,
                chainKey: chainKey,
                iteration: iteration
            )
        }

        isInitialized = true
    }

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

        // Persist to secure storage
        persistSenderKeys()

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

    /// Uploads our sender key to the server (encrypted for each member)
    /// The sender key is encrypted using each member's Double Ratchet session
    /// so the server never sees the plaintext key
    private func uploadSenderKey(for channelId: String, senderKey: OwnSenderKey) async throws {
        // Get channel members from server
        let membersResponse: ChannelMembersResponse = try await api.get("/groups/\(channelId)/members")

        let keyData = senderKey.chainKey.withUnsafeBytes { Data($0) }
        let currentUserId = secureStorage.userID ?? ""

        // Create sender key distribution message
        let distributionMessage = SenderKeyDistributionData(
            distributionId: senderKey.distributionId,
            chainKey: keyData.base64EncodedString(),
            iteration: senderKey.iteration
        )

        let distributionData = try JSONEncoder().encode(distributionMessage)

        // Encrypt for each member (except ourselves)
        var encryptedKeys: [EncryptedSenderKeyRequest] = []

        for member in membersResponse.members where member.userId != currentUserId {
            do {
                // Encrypt using their Double Ratchet session
                let encryptedData = try await signalService.encrypt(distributionData, for: member.userId)

                encryptedKeys.append(EncryptedSenderKeyRequest(
                    recipientId: member.userId,
                    encryptedKey: encryptedData.base64EncodedString()
                ))
            } catch {
                // If we don't have a session with this user, skip them
                // They'll request the key when they need it
                print("Could not encrypt sender key for \(member.userId): \(error)")
            }
        }

        // Upload all encrypted keys
        let request = UploadEncryptedSenderKeysRequest(
            channelId: channelId,
            distributionId: senderKey.distributionId,
            encryptedKeys: encryptedKeys
        )

        let _: MessageResponse = try await api.post("/groups/sender-key", body: request)
    }

    /// Fetches all sender keys for a channel (encrypted for us)
    /// Each key is decrypted using the sender's Double Ratchet session
    func fetchSenderKeys(for channelId: String) async throws {
        let response: EncryptedSenderKeysResponse = try await api.get("/groups/\(channelId)/sender-keys")

        var channelKeys: [String: SenderKeyData] = [:]

        for encryptedKey in response.senderKeys {
            guard let encryptedData = Data(base64Encoded: encryptedKey.encryptedKey) else {
                continue
            }

            do {
                // Decrypt using sender's Double Ratchet session
                let decryptedData = try await signalService.decrypt(encryptedData, from: encryptedKey.senderId)

                // Parse the distribution message
                let distributionMessage = try JSONDecoder().decode(SenderKeyDistributionData.self, from: decryptedData)

                guard let keyData = Data(base64Encoded: distributionMessage.chainKey) else {
                    continue
                }

                let chainKey = SymmetricKey(data: keyData)
                channelKeys[encryptedKey.senderId] = SenderKeyData(
                    distributionId: distributionMessage.distributionId,
                    chainKey: chainKey,
                    iteration: distributionMessage.iteration
                )
            } catch {
                // If decryption fails, skip this key
                // This could happen if the session was reset
                print("Could not decrypt sender key from \(encryptedKey.senderId): \(error)")
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

        // Increment iteration and persist
        ownSenderKeys[channelId]?.iteration += 1
        persistSenderKeys()

        return GroupCiphertext(
            distributionId: senderKey.distributionId,
            iteration: senderKey.iteration,
            ciphertext: combined
        )
    }

    /// Decrypts a group message using the sender's key
    /// SECURITY: Validates iteration to prevent replay attacks
    func decryptFromGroup(_ ciphertext: GroupCiphertext, from senderId: String, channelId: String) async throws -> Data {
        // Check if this is our own message
        let currentUserId = secureStorage.userID

        var chainKey: SymmetricKey
        var distributionId: String

        if senderId == currentUserId, let ownKey = ownSenderKeys[channelId] {
            // Use our own persisted key for our messages
            chainKey = ownKey.chainKey
            distributionId = ownKey.distributionId
        } else {
            // Get the sender's key from cache/server
            guard let senderKey = try await getSenderKey(for: senderId, in: channelId) else {
                throw SenderKeyError.senderKeyNotFound
            }
            chainKey = senderKey.chainKey
            distributionId = senderKey.distributionId
        }

        // Verify distribution ID matches
        guard distributionId == ciphertext.distributionId else {
            throw SenderKeyError.invalidDistributionId
        }

        // SECURITY: Check for replay attack - reject already-seen iterations
        if isIterationSeen(iteration: ciphertext.iteration, from: senderId, in: channelId) {
            throw SenderKeyError.replayAttackDetected
        }

        // Derive message key at the correct iteration
        let messageKey = deriveMessageKey(from: chainKey, iteration: ciphertext.iteration)

        // Decrypt with AES-GCM
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext.ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: messageKey)

        // Mark iteration as seen after successful decryption
        markIterationSeen(iteration: ciphertext.iteration, from: senderId, in: channelId)

        return plaintext
    }

    // MARK: - Replay Attack Prevention

    /// Checks if an iteration has already been seen (potential replay attack)
    private func isIterationSeen(iteration: Int, from senderId: String, in channelId: String) -> Bool {
        guard let channelIterations = seenIterations[channelId],
              let senderIterations = channelIterations[senderId] else {
            return false
        }
        return senderIterations.contains(iteration)
    }

    /// Marks an iteration as seen for replay detection
    private func markIterationSeen(iteration: Int, from senderId: String, in channelId: String) {
        // Initialize nested dictionaries if needed
        if seenIterations[channelId] == nil {
            seenIterations[channelId] = [:]
        }
        if seenIterations[channelId]?[senderId] == nil {
            seenIterations[channelId]?[senderId] = Set()
        }

        seenIterations[channelId]?[senderId]?.insert(iteration)

        // Limit memory usage by pruning old iterations when over limit
        if let count = seenIterations[channelId]?[senderId]?.count, count > maxSeenIterationsPerSender {
            // Keep only the highest iterations (most recent)
            if var iterations = seenIterations[channelId]?[senderId] {
                let sorted = iterations.sorted()
                let toKeep = sorted.suffix(maxSeenIterationsPerSender / 2)
                iterations = Set(toKeep)
                seenIterations[channelId]?[senderId] = iterations
            }
        }
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
        persistSenderKeys()

        // Generate and upload new key
        _ = try await generateSenderKey(for: channelId)
    }

    /// Clears cached keys for a channel (called when key rotation is detected)
    func clearChannelKeys(for channelId: String) {
        senderKeyCache.removeValue(forKey: channelId)
        ownSenderKeys.removeValue(forKey: channelId)
        persistSenderKeys()
    }

    /// Clears all cached keys
    func clearAllKeys() {
        senderKeyCache.removeAll()
        ownSenderKeys.removeAll()
        persistSenderKeys()
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

/// Internal structure for sender key distribution message
/// This is encrypted before being sent to each recipient
struct SenderKeyDistributionData: Codable {
    let distributionId: String
    let chainKey: String  // Base64-encoded chain key
    let iteration: Int

    enum CodingKeys: String, CodingKey {
        case distributionId = "distribution_id"
        case chainKey = "chain_key"
        case iteration
    }
}

/// Request to upload encrypted sender keys for channel members
struct UploadEncryptedSenderKeysRequest: Encodable {
    let channelId: String
    let distributionId: String
    let encryptedKeys: [EncryptedSenderKeyRequest]

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case distributionId = "distribution_id"
        case encryptedKeys = "encrypted_keys"
    }
}

/// Individual encrypted sender key for a recipient
struct EncryptedSenderKeyRequest: Encodable {
    let recipientId: String
    let encryptedKey: String  // Base64-encoded Double Ratchet encrypted data

    enum CodingKeys: String, CodingKey {
        case recipientId = "recipient_id"
        case encryptedKey = "encrypted_key"
    }
}

/// Response containing encrypted sender keys from channel members
struct EncryptedSenderKeysResponse: Decodable {
    let senderKeys: [EncryptedSenderKeyResponse]

    enum CodingKeys: String, CodingKey {
        case senderKeys = "sender_keys"
    }
}

/// Encrypted sender key from a channel member
struct EncryptedSenderKeyResponse: Decodable {
    let senderId: String
    let encryptedKey: String  // Base64-encoded, encrypted for us
    let distributionId: String

    enum CodingKeys: String, CodingKey {
        case senderId = "sender_id"
        case encryptedKey = "encrypted_key"
        case distributionId = "distribution_id"
    }
}

/// Response containing channel members
/// Uses ChannelMember from MessagingModels.swift
struct ChannelMembersResponse: Decodable {
    let members: [ChannelMemberBasic]
}

/// Basic channel member info for sender key distribution
/// (Separate from full ChannelMember to avoid import issues)
struct ChannelMemberBasic: Decodable {
    let userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
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
    case replayAttackDetected

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
        case .replayAttackDetected:
            return "Replay attack detected - message iteration already processed"
        }
    }
}
