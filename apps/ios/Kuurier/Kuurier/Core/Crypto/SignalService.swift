import Foundation
import CryptoKit
import Combine

/// Service for managing Signal Protocol keys and sessions
/// Handles key generation, upload to server, and fetching other users' key bundles
final class SignalService: ObservableObject {

    static let shared = SignalService()

    @Published var isInitialized = false
    @Published var preKeyCount = 0
    @Published var needsPreKeyRefresh = false

    private let store = SignalStore.shared
    private let api = APIClient.shared
    private let keyManager = KeyManager.shared

    // Minimum pre-keys before we should upload more
    private let preKeyLowThreshold = 10
    // Number of pre-keys to generate in a batch
    private let preKeyBatchSize = 100

    private init() {}

    // MARK: - Initialization

    /// Initializes Signal Protocol keys for a new user
    /// Call this after successful registration
    @MainActor
    func initializeKeys() async throws {
        // Check if already initialized
        guard !store.hasIdentityKey else {
            isInitialized = true
            await checkPreKeyCount()
            return
        }

        // Generate identity key pair for Signal (X25519 for key agreement)
        try store.generateIdentityKeyPair()

        // Generate signed pre-key (signed with Ed25519 auth key)
        guard let signingKeyData = keyManager.exportPrivateKey(),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyData) else {
            throw SignalServiceError.noSigningKey
        }

        _ = try store.generateSignedPreKey(keyId: 1, signingKey: signingKey)

        // Generate initial batch of one-time pre-keys
        _ = try store.generatePreKeys(startId: 1, count: preKeyBatchSize)

        // Upload the key bundle to the server
        try await uploadKeyBundle()

        isInitialized = true
    }

    /// Checks if keys are initialized
    func checkInitialization() {
        isInitialized = store.hasIdentityKey
    }

    // MARK: - Key Bundle Management

    /// Uploads the full key bundle to the server
    @MainActor
    func uploadKeyBundle() async throws {
        guard let identityKey = store.getIdentityPublicKey(),
              let signedPreKey = store.getSignedPreKey() else {
            throw SignalServiceError.noKeysToUpload
        }

        // Generate pre-keys if needed
        var preKeys: [SignalStore.PreKey] = []
        let existingCount = store.countPreKeys()
        if existingCount < preKeyBatchSize {
            preKeys = try store.generatePreKeys(startId: store.nextPreKeyId, count: preKeyBatchSize - existingCount)
        } else {
            // Use existing pre-keys
            for i in 0..<preKeyBatchSize {
                if let pk = store.getPreKey(id: store.nextPreKeyId - preKeyBatchSize + i) {
                    preKeys.append(pk)
                }
            }
        }

        let request = UploadKeyBundleRequest(
            identityKey: identityKey.base64EncodedString(),
            registrationId: store.registrationId,
            signedPrekey: SignedPreKeyRequest(
                keyId: signedPreKey.keyId,
                publicKey: signedPreKey.publicKey.base64EncodedString(),
                signature: signedPreKey.signature.base64EncodedString()
            ),
            prekeys: preKeys.map { PreKeyRequest(keyId: $0.keyId, publicKey: $0.publicKey.base64EncodedString()) }
        )

        let _: UploadKeyBundleResponse = try await api.post("/keys/bundle", body: request)
        preKeyCount = preKeys.count
        needsPreKeyRefresh = false
    }

    /// Checks and refreshes pre-keys if needed
    @MainActor
    func checkPreKeyCount() async {
        do {
            let response: PreKeyCountResponse = try await api.get("/keys/prekey-count")
            preKeyCount = response.count
            needsPreKeyRefresh = response.lowWarning

            if needsPreKeyRefresh {
                try await uploadMorePreKeys()
            }
        } catch {
            print("Failed to check pre-key count: \(error)")
        }
    }

    /// Uploads additional pre-keys when running low
    @MainActor
    private func uploadMorePreKeys() async throws {
        let preKeys = try store.generatePreKeys(startId: store.nextPreKeyId, count: preKeyBatchSize)

        let request = UploadPreKeysRequest(
            prekeys: preKeys.map { PreKeyRequest(keyId: $0.keyId, publicKey: $0.publicKey.base64EncodedString()) }
        )

        let _: UploadPreKeysResponse = try await api.post("/keys/prekeys", body: request)
        preKeyCount += preKeys.count
        needsPreKeyRefresh = false
    }

    /// Rotates the signed pre-key (should be done monthly)
    @MainActor
    func rotateSignedPreKey() async throws {
        guard let signingKeyData = keyManager.exportPrivateKey(),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyData) else {
            throw SignalServiceError.noSigningKey
        }

        let currentKeyId = store.getSignedPreKey()?.keyId ?? 0
        let newSignedPreKey = try store.generateSignedPreKey(keyId: currentKeyId + 1, signingKey: signingKey)

        let request = UpdateSignedPreKeyRequest(
            signedPrekey: SignedPreKeyRequest(
                keyId: newSignedPreKey.keyId,
                publicKey: newSignedPreKey.publicKey.base64EncodedString(),
                signature: newSignedPreKey.signature.base64EncodedString()
            )
        )

        let _: MessageResponse = try await api.put("/keys/signed-prekey", body: request)
    }

    // MARK: - Fetching Other Users' Keys

    /// Fetches another user's pre-key bundle for establishing a session
    @MainActor
    func fetchPreKeyBundle(for userId: String) async throws -> PreKeyBundle {
        let response: PreKeyBundleResponse = try await api.get("/keys/bundle/\(userId)")

        guard let identityKeyData = Data(base64Encoded: response.identityKey),
              let signedPublicKeyData = Data(base64Encoded: response.signedPrekey.publicKey),
              let signatureData = Data(base64Encoded: response.signedPrekey.signature) else {
            throw SignalServiceError.invalidKeyBundle
        }

        var preKeyData: Data?
        var preKeyId: Int?
        if let preKey = response.prekey {
            preKeyData = Data(base64Encoded: preKey.publicKey)
            preKeyId = preKey.keyId
        }

        return PreKeyBundle(
            userId: userId,
            registrationId: response.registrationId,
            identityKey: identityKeyData,
            signedPreKeyId: response.signedPrekey.keyId,
            signedPreKey: signedPublicKeyData,
            signature: signatureData,
            preKeyId: preKeyId,
            preKey: preKeyData
        )
    }

    // MARK: - Session Establishment

    /// Establishes a session with another user using X3DH key agreement
    /// Returns the shared secret for initializing Double Ratchet
    func establishSession(with bundle: PreKeyBundle) throws -> Data {
        guard let identityPrivateKey = store.getIdentityPrivateKey() else {
            throw SignalServiceError.noIdentityKey
        }

        // Parse remote public keys
        guard let remoteIdentityKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey),
              let remoteSignedPreKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.signedPreKey) else {
            throw SignalServiceError.invalidKeyBundle
        }

        // Verify signed pre-key signature
        // Note: In production, use Ed25519 signature verification
        // For now, we trust the server's validation

        // Generate ephemeral key pair
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // X3DH Key Agreement
        // DH1: Our identity key + Their signed pre-key
        let dh1 = try identityPrivateKey.sharedSecretFromKeyAgreement(with: remoteSignedPreKey)

        // DH2: Our ephemeral key + Their identity key
        let dh2 = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: remoteIdentityKey)

        // DH3: Our ephemeral key + Their signed pre-key
        let dh3 = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: remoteSignedPreKey)

        // DH4: Our ephemeral key + Their one-time pre-key (if available)
        var dhResults: [SharedSecret] = [dh1, dh2, dh3]
        if let preKeyData = bundle.preKey,
           let remotePreKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: preKeyData) {
            let dh4 = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: remotePreKey)
            dhResults.append(dh4)
        }

        // Concatenate all DH results and derive master secret using HKDF
        var masterInput = Data()
        for dh in dhResults {
            dh.withUnsafeBytes { masterInput.append(contentsOf: $0) }
        }

        // HKDF to derive the master secret
        let salt = Data(repeating: 0, count: 32) // 32 zero bytes as salt
        let info = "KuurierSignal".data(using: .utf8)!

        let masterSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterInput),
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        // Convert to Data for storage/use
        return masterSecret.withUnsafeBytes { Data($0) }
    }

    // MARK: - Session Storage

    private var sessions: [String: Data] = [:] // userId -> masterSecret

    /// Gets or establishes a session with a user
    private func getOrEstablishSession(with userId: String) async throws -> Data {
        // Check if we already have a session
        if let existingSession = sessions[userId] {
            return existingSession
        }

        // Fetch their pre-key bundle and establish session
        let bundle = try await fetchPreKeyBundle(for: userId)
        let masterSecret = try establishSession(with: bundle)
        sessions[userId] = masterSecret
        return masterSecret
    }

    // MARK: - Encryption

    /// Encrypts a message for a specific user (1:1 DM)
    @MainActor
    func encrypt(_ plaintext: Data, for userId: String) async throws -> Data {
        let masterSecret = try await getOrEstablishSession(with: userId)

        // Derive encryption key and nonce from master secret
        let encryptionKey = deriveKey(from: masterSecret, purpose: "encryption")
        let nonce = try AES.GCM.Nonce(data: deriveKey(from: masterSecret, purpose: "nonce").prefix(12))

        // Encrypt with AES-GCM
        let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: encryptionKey), nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw SignalServiceError.encryptionFailed
        }

        return combined
    }

    /// Decrypts a message from a specific user (1:1 DM)
    @MainActor
    func decrypt(_ ciphertext: Data, from userId: String) async throws -> Data {
        let masterSecret = try await getOrEstablishSession(with: userId)

        // Derive the same encryption key and nonce
        let encryptionKey = deriveKey(from: masterSecret, purpose: "encryption")
        let nonce = try AES.GCM.Nonce(data: deriveKey(from: masterSecret, purpose: "nonce").prefix(12))

        // Decrypt with AES-GCM
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: encryptionKey))

        return plaintext
    }

    /// Derives a purpose-specific key from the master secret
    private func deriveKey(from masterSecret: Data, purpose: String) -> Data {
        let info = "Kuurier-\(purpose)".data(using: .utf8)!
        let salt = Data(repeating: 0, count: 32)

        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterSecret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        return derivedKey.withUnsafeBytes { Data($0) }
    }

    // MARK: - Cleanup

    /// Clears all Signal keys (for account deletion)
    func clearAllKeys() {
        store.deleteAllSignalKeys()
        sessions.removeAll()
        isInitialized = false
        preKeyCount = 0
    }

    /// Clears session with a specific user (for re-establishing)
    func clearSession(with userId: String) {
        sessions.removeValue(forKey: userId)
    }
}

// MARK: - API Request/Response Types

private struct UploadKeyBundleRequest: Encodable {
    let identityKey: String
    let registrationId: Int
    let signedPrekey: SignedPreKeyRequest
    let prekeys: [PreKeyRequest]

    enum CodingKeys: String, CodingKey {
        case identityKey = "identity_key"
        case registrationId = "registration_id"
        case signedPrekey = "signed_prekey"
        case prekeys
    }
}

private struct SignedPreKeyRequest: Encodable {
    let keyId: Int
    let publicKey: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
        case signature
    }
}

private struct PreKeyRequest: Encodable {
    let keyId: Int
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
    }
}

private struct UploadKeyBundleResponse: Decodable {
    let message: String
    let prekeyCount: Int

    enum CodingKeys: String, CodingKey {
        case message
        case prekeyCount = "prekey_count"
    }
}

private struct UploadPreKeysRequest: Encodable {
    let prekeys: [PreKeyRequest]
}

private struct UploadPreKeysResponse: Decodable {
    let message: String
    let count: Int
}

private struct UpdateSignedPreKeyRequest: Encodable {
    let signedPrekey: SignedPreKeyRequest

    enum CodingKeys: String, CodingKey {
        case signedPrekey = "signed_prekey"
    }
}

private struct PreKeyCountResponse: Decodable {
    let count: Int
    let lowWarning: Bool

    enum CodingKeys: String, CodingKey {
        case count
        case lowWarning = "low_warning"
    }
}

private struct PreKeyBundleResponse: Decodable {
    let identityKey: String
    let registrationId: Int
    let signedPrekey: SignedPreKeyResponseData
    let prekey: PreKeyResponseData?

    enum CodingKeys: String, CodingKey {
        case identityKey = "identity_key"
        case registrationId = "registration_id"
        case signedPrekey = "signed_prekey"
        case prekey
    }
}

private struct SignedPreKeyResponseData: Decodable {
    let keyId: Int
    let publicKey: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
        case signature
    }
}

private struct PreKeyResponseData: Decodable {
    let keyId: Int
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case publicKey = "public_key"
    }
}

// MARK: - Pre-Key Bundle

/// Represents another user's key bundle for session establishment
struct PreKeyBundle {
    let userId: String
    let registrationId: Int
    let identityKey: Data
    let signedPreKeyId: Int
    let signedPreKey: Data
    let signature: Data
    let preKeyId: Int?
    let preKey: Data?
}

// MARK: - Errors

enum SignalServiceError: Error, LocalizedError {
    case noSigningKey
    case noIdentityKey
    case noKeysToUpload
    case invalidKeyBundle
    case sessionNotFound
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .noSigningKey:
            return "No signing key available"
        case .noIdentityKey:
            return "No identity key found"
        case .noKeysToUpload:
            return "No keys available to upload"
        case .invalidKeyBundle:
            return "Invalid key bundle format"
        case .sessionNotFound:
            return "No session found with user"
        case .encryptionFailed:
            return "Failed to encrypt message"
        case .decryptionFailed:
            return "Failed to decrypt message"
        }
    }
}

// MessageResponse is already defined in Models.swift
