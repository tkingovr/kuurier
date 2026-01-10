import Foundation
import Combine

/// Service for managing invite codes
final class InviteService: ObservableObject {

    static let shared = InviteService()

    @Published var invites: [InviteCode] = []
    @Published var totalAllowance: Int = 0
    @Published var usedCount: Int = 0
    @Published var activeCount: Int = 0
    @Published var availableToMake: Int = 0
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared

    private init() {}

    // MARK: - Fetch Invites

    /// Fetches all invite codes for the current user
    @MainActor
    func fetchInvites() async {
        isLoading = true
        error = nil

        do {
            let response: InvitesResponse = try await api.get("/invites")

            invites = response.invites
            totalAllowance = response.totalAllowance
            usedCount = response.usedCount
            activeCount = response.activeCount
            availableToMake = response.availableToMake
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Generate Invite

    /// Generates a new invite code
    @MainActor
    func generateInvite() async -> InviteCode? {
        isLoading = true
        error = nil

        do {
            let response: GenerateInviteResponse = try await api.post("/invites", body: EmptyRequest())

            // Refresh the list to get the new invite
            await fetchInvites()

            // Find and return the newly created invite
            return invites.first { $0.id == response.id }
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return nil
        }
    }

    // MARK: - Revoke Invite

    /// Revokes an unused invite code
    @MainActor
    func revokeInvite(code: String) async -> Bool {
        isLoading = true
        error = nil

        do {
            let _: MessageResponse = try await api.delete("/invites/\(code)")

            // Remove from local list
            invites.removeAll { $0.code == code }
            activeCount = max(0, activeCount - 1)
            availableToMake += 1
            isLoading = false
            return true
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return false
        }
    }

    // MARK: - Helpers

    /// Returns only active (unused, not expired) invites
    var activeInvites: [InviteCode] {
        invites.filter { $0.status == .active }
    }

    /// Returns only used invites
    var usedInvites: [InviteCode] {
        invites.filter { $0.status == .used }
    }

    /// Whether the user can generate more invites
    var canGenerateInvite: Bool {
        availableToMake > 0
    }
}

// Empty request body for POST
private struct EmptyRequest: Encodable {}
