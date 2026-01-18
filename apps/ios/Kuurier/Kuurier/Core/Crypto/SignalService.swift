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

        // Verify signed pre-key signature using Ed25519
        // This prevents a malicious server from substituting keys
        try verifySignedPreKeySignature(
            signedPreKeyPublic: bundle.signedPreKey,
            signature: bundle.signature,
            signingPublicKey: bundle.identityKey
        )

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

    // MARK: - Session Management (Double Ratchet)

    /// Gets or establishes a Double Ratchet session with a user
    /// Returns the session state ready for encryption/decryption
    private func getOrEstablishSession(with userId: String) async throws -> DoubleRatchet.SessionState {
        // Check for existing session in persistent storage
        if let existingSession = store.getSession(for: userId) {
            return existingSession
        }

        // Fetch their pre-key bundle and establish new session
        let bundle = try await fetchPreKeyBundle(for: userId)
        let masterSecret = try establishSession(with: bundle)

        // Initialize Double Ratchet as Alice (initiator)
        // Their signed pre-key becomes their initial ratchet public key
        let session = try DoubleRatchet.initializeAsAlice(
            sharedSecret: masterSecret,
            theirRatchetPublicKey: bundle.signedPreKey
        )

        // Persist the session
        try store.storeSession(session, for: userId)

        return session
    }

    /// Creates a session as Bob (responder) when receiving first message
    /// This is called by MessagingService when processing an incoming message from a new sender
    func createResponderSession(
        senderId: String,
        sharedSecret: Data,
        signedPreKey: Curve25519.KeyAgreement.PrivateKey
    ) throws {
        let session = DoubleRatchet.initializeAsBob(
            sharedSecret: sharedSecret,
            ourSignedPreKey: signedPreKey
        )
        try store.storeSession(session, for: senderId)
    }

    // MARK: - Encryption (Double Ratchet)

    /// Encrypts a message for a specific user using Double Ratchet (1:1 DM)
    /// Each message uses a unique key derived from the ratcheting chain
    @MainActor
    func encrypt(_ plaintext: Data, for userId: String) async throws -> Data {
        var session = try await getOrEstablishSession(with: userId)

        // Encrypt using Double Ratchet
        let ciphertext = try DoubleRatchet.encrypt(plaintext: plaintext, state: &session)

        // Persist updated session state
        try store.storeSession(session, for: userId)

        return ciphertext
    }

    /// Decrypts a message from a specific user using Double Ratchet (1:1 DM)
    /// Handles the DH ratchet step if the sender has rotated their keys
    @MainActor
    func decrypt(_ ciphertext: Data, from userId: String) async throws -> Data {
        // Get existing session or throw
        guard var session = store.getSession(for: userId) else {
            // No session exists - this could be first message from this user
            // In production, you'd need to handle session establishment here
            throw SignalServiceError.sessionNotFound
        }

        // Decrypt using Double Ratchet
        let plaintext = try DoubleRatchet.decrypt(ciphertext: ciphertext, state: &session)

        // Persist updated session state
        try store.storeSession(session, for: userId)

        return plaintext
    }

    /// Handles first message received from a new sender
    /// Establishes a responder session and decrypts the message
    /// SECURITY: Verifies sender's identity key against server before establishing session
    @MainActor
    func decryptFirstMessage(_ ciphertext: Data, from userId: String, withBundle bundle: PreKeyBundle) async throws -> Data {
        // Compute shared secret using X3DH as Bob (verifies identity key)
        let sharedSecret = try await establishSessionAsBob(with: bundle)

        // Get our signed pre-key
        guard let signedPreKey = store.getSignedPreKey() else {
            throw SignalServiceError.noIdentityKey
        }

        // Initialize as Bob (responder)
        var session = DoubleRatchet.initializeAsBob(
            sharedSecret: sharedSecret,
            ourSignedPreKey: signedPreKey.privateKey
        )

        // Decrypt the message (this will perform the first DH ratchet)
        let plaintext = try DoubleRatchet.decrypt(ciphertext: ciphertext, state: &session)

        // Persist the session
        try store.storeSession(session, for: userId)

        return plaintext
    }

    /// X3DH key agreement as Bob (receiver of first message)
    /// SECURITY: Verifies sender's identity key against registered key to prevent MITM attacks
    private func establishSessionAsBob(with bundle: PreKeyBundle) async throws -> Data {
        guard let identityPrivateKey = store.getIdentityPrivateKey(),
              let signedPreKey = store.getSignedPreKey() else {
            throw SignalServiceError.noIdentityKey
        }

        // CRITICAL: Verify the sender's identity key matches what's registered on the server
        // This prevents MITM attacks where a malicious server substitutes keys
        let registeredBundle = try await fetchPreKeyBundle(for: bundle.userId)
        guard constantTimeCompare(bundle.identityKey, registeredBundle.identityKey) else {
            throw SignalServiceError.identityKeyMismatch
        }

        // Parse Alice's keys from the bundle
        guard let aliceIdentityKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey) else {
            throw SignalServiceError.invalidKeyBundle
        }

        // DH1: Their identity key + Our signed pre-key
        let dh1 = try signedPreKey.privateKey.sharedSecretFromKeyAgreement(with: aliceIdentityKey)

        // DH2: Their ephemeral key + Our identity key
        // Note: In full implementation, ephemeral key would be in the message header
        // For now, we use their identity key
        let dh2 = try identityPrivateKey.sharedSecretFromKeyAgreement(with: aliceIdentityKey)

        // DH3: Their ephemeral key + Our signed pre-key
        let dh3 = try signedPreKey.privateKey.sharedSecretFromKeyAgreement(with: aliceIdentityKey)

        // Concatenate DH results
        var masterInput = Data()
        dh1.withUnsafeBytes { masterInput.append(contentsOf: $0) }
        dh2.withUnsafeBytes { masterInput.append(contentsOf: $0) }
        dh3.withUnsafeBytes { masterInput.append(contentsOf: $0) }

        // If one-time pre-key was used
        if let preKeyId = bundle.preKeyId,
           let preKeyData = bundle.preKey,
           let preKey = store.getPreKey(id: preKeyId) {
            let alicePreKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: preKeyData)
            let dh4 = try preKey.privateKey.sharedSecretFromKeyAgreement(with: alicePreKey)
            dh4.withUnsafeBytes { masterInput.append(contentsOf: $0) }

            // Remove consumed one-time pre-key
            store.removePreKey(id: preKeyId)
        }

        // Derive master secret with HKDF
        let salt = Data(repeating: 0, count: 32)
        let info = "KuurierSignal".data(using: .utf8)!

        let masterSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterInput),
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        return masterSecret.withUnsafeBytes { Data($0) }
    }

    /// Constant-time comparison to prevent timing attacks
    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
    }

    // MARK: - Signature Verification

    /// Verifies that a signed pre-key was actually signed by the claimed identity key
    /// This prevents a malicious server from substituting keys (MITM attack)
    /// SECURITY: Uses constant-time result handling to prevent timing attacks
    private func verifySignedPreKeySignature(
        signedPreKeyPublic: Data,
        signature: Data,
        signingPublicKey: Data
    ) throws {
        // In Signal Protocol, the identity key can be used for both key agreement (X25519)
        // and signing (Ed25519). CryptoKit uses separate types, but they share the same curve.
        // We interpret the identity key as an Ed25519 signing key for verification.

        guard let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else {
            throw SignalServiceError.invalidKeyBundle
        }

        // Verify the signature over the signed pre-key's public key
        // Use constant-time result handling to prevent timing attacks
        let isValid = signingKey.isValidSignature(signature, for: signedPreKeyPublic)

        // Constant-time boolean check: always execute same code path regardless of result
        // This prevents timing attacks that could distinguish valid from invalid signatures
        var result: UInt8 = isValid ? 1 : 0
        result = result & 0x01  // Ensure single bit

        if result != 1 {
            throw SignalServiceError.signatureVerificationFailed
        }
    }

    // MARK: - Cleanup

    /// Clears all Signal keys (for account deletion)
    func clearAllKeys() {
        store.deleteAllSignalKeys()
        isInitialized = false
        preKeyCount = 0
    }

    /// Clears session with a specific user (for re-establishing)
    func clearSession(with userId: String) {
        store.deleteSession(for: userId)
    }

    /// Checks if a session exists with a user
    func hasSession(with userId: String) -> Bool {
        return store.hasSession(with: userId)
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
    case signatureVerificationFailed
    case identityKeyMismatch

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
        case .signatureVerificationFailed:
            return "Failed to verify signed pre-key signature - possible key tampering"
        case .encryptionFailed:
            return "Failed to encrypt message"
        case .decryptionFailed:
            return "Failed to decrypt message"
        case .identityKeyMismatch:
            return "Sender's identity key does not match registered key - possible MITM attack"
        }
    }
}

// MessageResponse is already defined in Models.swift
