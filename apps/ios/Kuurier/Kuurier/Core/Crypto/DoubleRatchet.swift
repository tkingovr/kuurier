import Foundation
import CryptoKit

/// Double Ratchet Algorithm implementation for Signal Protocol
/// Provides forward secrecy and break-in recovery for encrypted messaging
///
/// The Double Ratchet combines:
/// 1. A symmetric-key ratchet (KDF chain) - advances with each message
/// 2. A Diffie-Hellman ratchet - advances when receiving new keys from peer
final class DoubleRatchet {

    // MARK: - Constants

    private static let maxSkip = 1000 // Maximum messages to skip in a chain
    private static let maxSkippedKeys = 2000 // Maximum skipped keys to store
    private static let maxSkippedKeyAge: TimeInterval = 86400 // 24 hours max age for skipped keys

    // MARK: - Session State

    /// Represents the state of a Double Ratchet session
    struct SessionState: Codable {
        // Root key - used to derive new chain keys during DH ratchet
        var rootKey: Data

        // Our current ratchet key pair
        var ourRatchetPrivateKey: Data
        var ourRatchetPublicKey: Data

        // Their current ratchet public key
        var theirRatchetPublicKey: Data?

        // Sending chain state
        var sendingChainKey: Data?
        var sendingMessageNumber: Int = 0

        // Receiving chain state
        var receivingChainKey: Data?
        var receivingMessageNumber: Int = 0

        // Previous sending chain length (for header)
        var previousChainLength: Int = 0

        // Skipped message keys for out-of-order messages
        var skippedMessageKeys: [SkippedKey] = []

        // Whether we've sent the first message (determines who does initial DH ratchet)
        var hasReceivedFirstMessage: Bool = false
    }

    /// Represents a skipped message key
    struct SkippedKey: Codable {
        let ratchetPublicKey: Data
        let messageNumber: Int
        let messageKey: Data
        let timestamp: Date
    }

    /// Message header containing ratchet state
    struct MessageHeader: Codable {
        let ratchetPublicKey: Data  // Sender's current ratchet public key
        let previousChainLength: Int  // Length of previous sending chain
        let messageNumber: Int  // Message number in current chain

        func serialize() -> Data {
            // Format: publicKey (32) + prevChainLen (4) + msgNum (4) = 40 bytes
            var data = Data()
            data.append(ratchetPublicKey)

            var prevLen = UInt32(previousChainLength)
            data.append(Data(bytes: &prevLen, count: 4))

            var msgNum = UInt32(messageNumber)
            data.append(Data(bytes: &msgNum, count: 4))

            return data
        }

        static func deserialize(from data: Data) throws -> MessageHeader {
            guard data.count >= 40 else {
                throw DoubleRatchetError.invalidHeader
            }

            let publicKey = data.prefix(32)
            let prevLen = Int(data.dropFirst(32).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })
            let msgNum = Int(data.dropFirst(36).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) })

            return MessageHeader(
                ratchetPublicKey: Data(publicKey),
                previousChainLength: prevLen,
                messageNumber: msgNum
            )
        }
    }

    /// Encrypted message format
    struct EncryptedMessage: Codable {
        let header: Data  // Serialized MessageHeader (40 bytes)
        let ciphertext: Data  // AES-GCM encrypted content

        func serialize() -> Data {
            // Format: headerLen (2) + header + ciphertext
            var data = Data()
            var headerLen = UInt16(header.count)
            data.append(Data(bytes: &headerLen, count: 2))
            data.append(header)
            data.append(ciphertext)
            return data
        }

        static func deserialize(from data: Data) throws -> EncryptedMessage {
            guard data.count >= 2 else {
                throw DoubleRatchetError.invalidMessage
            }

            let headerLen = Int(data.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) })
            guard data.count >= 2 + headerLen else {
                throw DoubleRatchetError.invalidMessage
            }

            let header = data.dropFirst(2).prefix(headerLen)
            let ciphertext = data.dropFirst(2 + headerLen)

            return EncryptedMessage(header: Data(header), ciphertext: Data(ciphertext))
        }
    }

    // MARK: - Session Management

    /// Initializes a session as the initiator (Alice) after X3DH
    /// Alice sends the first message
    static func initializeAsAlice(
        sharedSecret: Data,
        theirRatchetPublicKey: Data
    ) throws -> SessionState {
        // Generate our initial ratchet key pair
        let ourRatchetKey = Curve25519.KeyAgreement.PrivateKey()

        // Perform initial DH ratchet
        guard let theirPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirRatchetPublicKey) else {
            throw DoubleRatchetError.invalidPublicKey
        }

        let dhOutput = try ourRatchetKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        let dhOutputData = dhOutput.withUnsafeBytes { Data($0) }

        // Derive root key and sending chain key
        let (newRootKey, sendingChainKey) = kdfRootKey(
            rootKey: sharedSecret,
            dhOutput: dhOutputData
        )

        return SessionState(
            rootKey: newRootKey,
            ourRatchetPrivateKey: ourRatchetKey.rawRepresentation,
            ourRatchetPublicKey: ourRatchetKey.publicKey.rawRepresentation,
            theirRatchetPublicKey: theirRatchetPublicKey,
            sendingChainKey: sendingChainKey,
            sendingMessageNumber: 0,
            receivingChainKey: nil,
            receivingMessageNumber: 0,
            previousChainLength: 0,
            skippedMessageKeys: [],
            hasReceivedFirstMessage: false
        )
    }

    /// Initializes a session as the responder (Bob) after X3DH
    /// Bob receives the first message before sending
    static func initializeAsBob(
        sharedSecret: Data,
        ourSignedPreKey: Curve25519.KeyAgreement.PrivateKey
    ) -> SessionState {
        // Use signed pre-key as initial ratchet key
        return SessionState(
            rootKey: sharedSecret,
            ourRatchetPrivateKey: ourSignedPreKey.rawRepresentation,
            ourRatchetPublicKey: ourSignedPreKey.publicKey.rawRepresentation,
            theirRatchetPublicKey: nil,
            sendingChainKey: nil,
            sendingMessageNumber: 0,
            receivingChainKey: nil,
            receivingMessageNumber: 0,
            previousChainLength: 0,
            skippedMessageKeys: [],
            hasReceivedFirstMessage: false
        )
    }

    // MARK: - Encryption

    /// Encrypts a message using the Double Ratchet
    static func encrypt(
        plaintext: Data,
        state: inout SessionState
    ) throws -> Data {
        // Ensure we have a sending chain key
        guard let chainKey = state.sendingChainKey else {
            throw DoubleRatchetError.noSendingChain
        }

        // Derive message key from chain key
        let (newChainKey, messageKey) = kdfChainKey(chainKey: chainKey)

        // Update chain key
        state.sendingChainKey = newChainKey

        // Create header
        let header = MessageHeader(
            ratchetPublicKey: state.ourRatchetPublicKey,
            previousChainLength: state.previousChainLength,
            messageNumber: state.sendingMessageNumber
        )

        // Increment message number
        state.sendingMessageNumber += 1

        // Encrypt plaintext with message key
        let ciphertext = try encryptWithMessageKey(
            plaintext: plaintext,
            messageKey: messageKey,
            associatedData: header.serialize()
        )

        // Create encrypted message
        let message = EncryptedMessage(
            header: header.serialize(),
            ciphertext: ciphertext
        )

        return message.serialize()
    }

    // MARK: - Decryption

    /// Decrypts a message using the Double Ratchet
    static func decrypt(
        ciphertext: Data,
        state: inout SessionState
    ) throws -> Data {
        // Parse the message
        let message = try EncryptedMessage.deserialize(from: ciphertext)
        let header = try MessageHeader.deserialize(from: message.header)

        // Try to find a skipped message key first
        if let plaintext = trySkippedMessageKeys(
            header: header,
            ciphertext: message.ciphertext,
            state: &state
        ) {
            return plaintext
        }

        // Check if we need to perform a DH ratchet
        if state.theirRatchetPublicKey == nil || header.ratchetPublicKey != state.theirRatchetPublicKey {
            // Skip any messages from the previous receiving chain
            try skipMessageKeys(until: header.previousChainLength, state: &state)

            // Perform DH ratchet
            try dhRatchet(theirPublicKey: header.ratchetPublicKey, state: &state)
        }

        // Skip messages if needed (out of order)
        try skipMessageKeys(until: header.messageNumber, state: &state)

        // Derive message key
        guard let chainKey = state.receivingChainKey else {
            throw DoubleRatchetError.noReceivingChain
        }

        let (newChainKey, messageKey) = kdfChainKey(chainKey: chainKey)
        state.receivingChainKey = newChainKey
        state.receivingMessageNumber += 1

        // Decrypt
        let plaintext = try decryptWithMessageKey(
            ciphertext: message.ciphertext,
            messageKey: messageKey,
            associatedData: message.header
        )

        state.hasReceivedFirstMessage = true

        return plaintext
    }

    // MARK: - DH Ratchet

    /// Performs a Diffie-Hellman ratchet step
    private static func dhRatchet(
        theirPublicKey: Data,
        state: inout SessionState
    ) throws {
        // Save previous chain length
        state.previousChainLength = state.sendingMessageNumber
        state.sendingMessageNumber = 0
        state.receivingMessageNumber = 0

        // Update their ratchet public key
        state.theirRatchetPublicKey = theirPublicKey

        // Parse their public key
        guard let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublicKey),
              let ourPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.ourRatchetPrivateKey) else {
            throw DoubleRatchetError.invalidPublicKey
        }

        // DH with our current private key and their new public key
        let dhOutput1 = try ourPrivateKey.sharedSecretFromKeyAgreement(with: theirKey)
        let dhOutputData1 = dhOutput1.withUnsafeBytes { Data($0) }

        // Derive new receiving chain key
        let (newRootKey1, receivingChainKey) = kdfRootKey(
            rootKey: state.rootKey,
            dhOutput: dhOutputData1
        )
        state.rootKey = newRootKey1
        state.receivingChainKey = receivingChainKey

        // Generate new ratchet key pair
        let newRatchetKey = Curve25519.KeyAgreement.PrivateKey()
        state.ourRatchetPrivateKey = newRatchetKey.rawRepresentation
        state.ourRatchetPublicKey = newRatchetKey.publicKey.rawRepresentation

        // DH with our new private key and their public key
        let dhOutput2 = try newRatchetKey.sharedSecretFromKeyAgreement(with: theirKey)
        let dhOutputData2 = dhOutput2.withUnsafeBytes { Data($0) }

        // Derive new sending chain key
        let (newRootKey2, sendingChainKey) = kdfRootKey(
            rootKey: state.rootKey,
            dhOutput: dhOutputData2
        )
        state.rootKey = newRootKey2
        state.sendingChainKey = sendingChainKey
    }

    // MARK: - Skipped Message Keys

    /// Tries to decrypt using a skipped message key
    private static func trySkippedMessageKeys(
        header: MessageHeader,
        ciphertext: Data,
        state: inout SessionState
    ) -> Data? {
        // Find matching skipped key
        guard let index = state.skippedMessageKeys.firstIndex(where: {
            $0.ratchetPublicKey == header.ratchetPublicKey &&
            $0.messageNumber == header.messageNumber
        }) else {
            return nil
        }

        let skippedKey = state.skippedMessageKeys[index]

        // Try to decrypt
        guard let plaintext = try? decryptWithMessageKey(
            ciphertext: ciphertext,
            messageKey: skippedKey.messageKey,
            associatedData: header.serialize()
        ) else {
            return nil
        }

        // Remove used key
        state.skippedMessageKeys.remove(at: index)

        return plaintext
    }

    /// Skips message keys up to a given number (stores them for later)
    private static func skipMessageKeys(until messageNumber: Int, state: inout SessionState) throws {
        guard let chainKey = state.receivingChainKey else {
            // No receiving chain yet, nothing to skip
            return
        }

        let toSkip = messageNumber - state.receivingMessageNumber
        guard toSkip >= 0 else {
            throw DoubleRatchetError.messageAlreadyDecrypted
        }

        guard toSkip <= maxSkip else {
            throw DoubleRatchetError.tooManySkippedMessages
        }

        guard let theirPublicKey = state.theirRatchetPublicKey else {
            return
        }

        var currentChainKey = chainKey

        for i in state.receivingMessageNumber..<messageNumber {
            let (newChainKey, messageKey) = kdfChainKey(chainKey: currentChainKey)
            currentChainKey = newChainKey

            // Store skipped key
            let skippedKey = SkippedKey(
                ratchetPublicKey: theirPublicKey,
                messageNumber: i,
                messageKey: messageKey,
                timestamp: Date()
            )
            state.skippedMessageKeys.append(skippedKey)

            // SECURITY: Smart eviction policy to prevent DoS attacks
            // 1. First, remove expired keys (older than maxSkippedKeyAge)
            // 2. Then apply count limit if still over, removing oldest first
            evictExpiredKeys(state: &state)
        }

        // Update receiving chain state after skipping
        state.receivingChainKey = currentChainKey
        state.receivingMessageNumber = messageNumber
    }

    /// Smart eviction policy for skipped message keys
    /// Prevents DoS attacks by prioritizing removal of expired keys
    private static func evictExpiredKeys(state: inout SessionState) {
        let now = Date()

        // First pass: remove all expired keys (age-based eviction)
        state.skippedMessageKeys.removeAll { key in
            now.timeIntervalSince(key.timestamp) > maxSkippedKeyAge
        }

        // Second pass: if still over limit, remove oldest keys (count-based eviction)
        if state.skippedMessageKeys.count > maxSkippedKeys {
            // Sort by timestamp (oldest first)
            state.skippedMessageKeys.sort { $0.timestamp < $1.timestamp }

            // Keep only the newest maxSkippedKeys entries
            let toRemove = state.skippedMessageKeys.count - maxSkippedKeys
            state.skippedMessageKeys.removeFirst(toRemove)
        }
    }

    // MARK: - Key Derivation Functions

    /// KDF for root key ratchet
    /// Returns (new root key, chain key)
    private static func kdfRootKey(rootKey: Data, dhOutput: Data) -> (Data, Data) {
        // Combine root key and DH output
        var input = Data()
        input.append(rootKey)
        input.append(dhOutput)

        // Use HKDF with different info strings for each output
        let rootKeyInfo = "KuurierRootKey".data(using: .utf8)!
        let chainKeyInfo = "KuurierChainKey".data(using: .utf8)!
        let salt = Data(repeating: 0, count: 32)

        let newRootKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: rootKeyInfo,
            outputByteCount: 32
        )

        let chainKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: chainKeyInfo,
            outputByteCount: 32
        )

        return (
            newRootKey.withUnsafeBytes { Data($0) },
            chainKey.withUnsafeBytes { Data($0) }
        )
    }

    /// KDF for chain key ratchet
    /// Returns (new chain key, message key)
    private static func kdfChainKey(chainKey: Data) -> (Data, Data) {
        // Use HMAC-SHA256 for chain key derivation
        let messageKeyInput = Data([0x01])
        let chainKeyInput = Data([0x02])

        let symmetricKey = SymmetricKey(data: chainKey)

        // Message key = HMAC(chain_key, 0x01)
        let messageKeyHMAC = HMAC<SHA256>.authenticationCode(for: messageKeyInput, using: symmetricKey)
        let messageKey = Data(messageKeyHMAC)

        // New chain key = HMAC(chain_key, 0x02)
        let chainKeyHMAC = HMAC<SHA256>.authenticationCode(for: chainKeyInput, using: symmetricKey)
        let newChainKey = Data(chainKeyHMAC)

        return (newChainKey, messageKey)
    }

    // MARK: - Symmetric Encryption

    /// Encrypts plaintext with a message key using AES-GCM
    private static func encryptWithMessageKey(
        plaintext: Data,
        messageKey: Data,
        associatedData: Data
    ) throws -> Data {
        // Derive encryption key and nonce from message key
        let encKeyInfo = "KuurierEnc".data(using: .utf8)!
        let nonceInfo = "KuurierNonce".data(using: .utf8)!
        let salt = Data(repeating: 0, count: 32)

        let encKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageKey),
            salt: salt,
            info: encKeyInfo,
            outputByteCount: 32
        )

        let nonceData = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageKey),
            salt: salt,
            info: nonceInfo,
            outputByteCount: 12
        )

        let nonce = try AES.GCM.Nonce(data: nonceData.withUnsafeBytes { Data($0) })

        // Encrypt with AES-GCM including associated data
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: encKey,
            nonce: nonce,
            authenticating: associatedData
        )

        guard let combined = sealedBox.combined else {
            throw DoubleRatchetError.encryptionFailed
        }

        return combined
    }

    /// Decrypts ciphertext with a message key using AES-GCM
    private static func decryptWithMessageKey(
        ciphertext: Data,
        messageKey: Data,
        associatedData: Data
    ) throws -> Data {
        // Derive encryption key from message key
        let encKeyInfo = "KuurierEnc".data(using: .utf8)!
        let salt = Data(repeating: 0, count: 32)

        let encKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: messageKey),
            salt: salt,
            info: encKeyInfo,
            outputByteCount: 32
        )

        // Decrypt with AES-GCM - nonce is embedded in the combined ciphertext
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: encKey, authenticating: associatedData)

        return plaintext
    }

    // MARK: - Serialization

    /// Serializes session state for storage
    static func serializeState(_ state: SessionState) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(state)
    }

    /// Deserializes session state from storage
    static func deserializeState(_ data: Data) throws -> SessionState {
        let decoder = JSONDecoder()
        return try decoder.decode(SessionState.self, from: data)
    }
}

// MARK: - Errors

enum DoubleRatchetError: Error, LocalizedError {
    case invalidHeader
    case invalidMessage
    case invalidPublicKey
    case noSendingChain
    case noReceivingChain
    case messageAlreadyDecrypted
    case tooManySkippedMessages
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid message header"
        case .invalidMessage:
            return "Invalid encrypted message format"
        case .invalidPublicKey:
            return "Invalid public key"
        case .noSendingChain:
            return "No sending chain established"
        case .noReceivingChain:
            return "No receiving chain established"
        case .messageAlreadyDecrypted:
            return "Message has already been decrypted"
        case .tooManySkippedMessages:
            return "Too many skipped messages"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        }
    }
}
