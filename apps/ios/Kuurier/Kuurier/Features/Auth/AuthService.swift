import Foundation
import Combine

/// Handles anonymous authentication using Ed25519 keypairs
final class AuthService: ObservableObject {

    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared
    private let keyManager = KeyManager.shared
    private let storage = SecureStorage.shared

    private init() {
        // Check if already logged in
        isAuthenticated = storage.isLoggedIn
    }

    // MARK: - Registration & Login

    /// Creates a new account or logs in if keypair exists
    func authenticate() async {
        await MainActor.run { isLoading = true; error = nil }

        do {
            let publicKey: Data

            // Check if we have an existing keypair
            if let existingKey = keyManager.getPublicKey() {
                publicKey = existingKey
            } else {
                // Generate new keypair
                publicKey = try keyManager.generateKeyPair()
            }

            // Base64 encode the public key
            let publicKeyBase64 = publicKey.base64EncodedString()

            // Request challenge from server
            let challengeResponse: AuthChallenge = try await api.post("/auth/register", body: [
                "public_key": publicKeyBase64
            ])

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
