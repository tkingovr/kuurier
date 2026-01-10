import Foundation
import Combine

/// Response from invite validation endpoint
struct InviteValidation: Codable {
    let valid: Bool
    let expiresAt: Date?
    let error: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case valid
        case expiresAt = "expires_at"
        case error
        case message
    }
}

/// Handles anonymous authentication using Ed25519 keypairs
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var error: String?
    @Published var inviteError: String?

    private let api = APIClient.shared
    private let keyManager = KeyManager.shared
    private let storage = SecureStorage.shared

    private init() {
        // Check if already logged in
        isAuthenticated = storage.isLoggedIn
    }

    // MARK: - Invite Validation

    /// Validates an invite code before registration
    func validateInviteCode(_ code: String) async -> Bool {
        await MainActor.run { isLoading = true; inviteError = nil }

        do {
            let response: InviteValidation = try await api.get("/invites/validate/\(code)")

            await MainActor.run {
                isLoading = false
                if !response.valid {
                    inviteError = response.message ?? response.error ?? "Invalid invite code"
                }
            }

            return response.valid
        } catch {
            await MainActor.run {
                isLoading = false
                inviteError = "Could not validate invite code"
            }
            return false
        }
    }

    // MARK: - Registration & Login

    /// Creates a new account with invite code or logs in if keypair exists
    func authenticate(inviteCode: String? = nil) async {
        await MainActor.run { isLoading = true; error = nil }

        do {
            let publicKey: Data
            let hasExistingKey = keyManager.getPublicKey() != nil

            // Check if we have an existing keypair
            if let existingKey = keyManager.getPublicKey() {
                publicKey = existingKey
            } else {
                // New registration requires invite code
                guard let inviteCode = inviteCode, !inviteCode.isEmpty else {
                    await MainActor.run {
                        error = "Invite code required for new registration"
                        isLoading = false
                    }
                    return
                }
                // Generate new keypair
                publicKey = try keyManager.generateKeyPair()
            }

            // Base64 encode the public key
            let publicKeyBase64 = publicKey.base64EncodedString()

            // Build request body with invite code for new registrations
            let requestBody = RegisterRequest(
                publicKey: publicKeyBase64,
                inviteCode: hasExistingKey ? nil : inviteCode
            )

            // Request challenge from server
            let challengeResponse: AuthChallenge = try await api.post("/auth/register", body: requestBody)

            // Sign the challenge with our private key
            let signature = try keyManager.sign(challenge: challengeResponse.challenge)
            let signatureBase64 = signature.base64EncodedString()

            // Verify signature with server
            let tokenResponse: AuthToken = try await api.post("/auth/verify", body: [
                "user_id": challengeResponse.userId,
                "challenge": challengeResponse.challenge,
                "signature": signatureBase64
            ])

            // Store credentials
            storage.authToken = tokenResponse.token
            storage.userID = challengeResponse.userId

            // Fetch user profile
            await fetchCurrentUser()

            await MainActor.run {
                isAuthenticated = true
                isLoading = false
            }

        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Fetches the current user's profile
    func fetchCurrentUser() async {
        do {
            let user: User = try await api.get("/me")
            await MainActor.run {
                currentUser = user
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
            }
        }
    }

    /// Logs out and clears credentials
    func logout() {
        storage.authToken = nil
        storage.userID = nil
        currentUser = nil
        isAuthenticated = false
    }

    /// Permanently deletes the account
    func deleteAccount() async throws {
        let _: MessageResponse = try await api.delete("/me")

        // Clear everything
        keyManager.deleteAllKeys()
        storage.clearAll()

        await MainActor.run {
            currentUser = nil
            isAuthenticated = false
        }
    }

    // MARK: - Web of Trust

    /// Vouches for another user
    func vouch(forUserID userID: String) async throws {
        let _: MessageResponse = try await api.post("/vouch/\(userID)", body: EmptyBody())
    }

    // MARK: - Recovery

    /// Exports private key for backup
    func exportRecoveryData() -> Data? {
        return keyManager.exportPrivateKey()
    }

    /// Imports private key for recovery
    func importRecoveryData(_ data: Data) async throws {
        try keyManager.importPrivateKey(data)
        await authenticate()
    }

    // MARK: - Panic Button

    /// Wipes all data immediately
    func panicWipe() {
        storage.panicWipe()
        currentUser = nil
        isAuthenticated = false
    }
}

// Helper for empty request bodies
private struct EmptyBody: Encodable {}

// Registration request body
private struct RegisterRequest: Encodable {
    let publicKey: String
    let inviteCode: String?
}
