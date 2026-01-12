import Foundation
import Combine

/// Service for managing organizations, channels, and messaging
final class MessagingService: ObservableObject {

    static let shared = MessagingService()

    // MARK: - Published State

    @Published var organizations: [Organization] = []
    @Published var channels: [Channel] = []
    @Published var activeOrganization: Organization?
    @Published var activeChannel: Channel?

    @Published var isLoadingOrgs = false
    @Published var isLoadingChannels = false
    @Published var error: String?

    // Unread counts
    @Published var totalUnreadCount: Int = 0

    private let api = APIClient.shared
    private let signalService = SignalService.shared

    private init() {}

    // MARK: - Organizations

    /// Fetches organizations the user is a member of
    @MainActor
    func fetchOrganizations() async {
        isLoadingOrgs = true
        error = nil

        do {
            let response: OrganizationsResponse = try await api.get("/orgs")
            organizations = response.organizations
        } catch {
            self.error = error.localizedDescription
        }

        isLoadingOrgs = false
    }

    /// Creates a new organization
    @MainActor
    func createOrganization(name: String, description: String?, isPublic: Bool) async throws -> Organization {
        let request = CreateOrganizationRequest(
            name: name,
            description: description,
            isPublic: isPublic
        )

        let org: Organization = try await api.post("/orgs", body: request)
        organizations.insert(org, at: 0)
        return org
    }

    /// Joins a public organization
    @MainActor
    func joinOrganization(id: String) async throws {
        let _: MessageResponse = try await api.post("/orgs/\(id)/join", body: EmptyRequest())
        await fetchOrganizations()
    }

    /// Leaves an organization
    @MainActor
    func leaveOrganization(id: String) async throws {
        let _: MessageResponse = try await api.post("/orgs/\(id)/leave", body: EmptyRequest())
        organizations.removeAll { $0.id == id }
        if activeOrganization?.id == id {
            activeOrganization = nil
        }
    }

    /// Discovers public organizations
    @MainActor
    func discoverOrganizations() async throws -> [Organization] {
        let response: OrganizationsResponse = try await api.get("/orgs/discover")
        return response.organizations
    }

    // MARK: - Channels

    /// Fetches channels the user is a member of
    @MainActor
    func fetchChannels(forOrg orgId: String? = nil) async {
        isLoadingChannels = true
        error = nil

        do {
            var queryItems: [URLQueryItem] = []
            if let orgId = orgId {
                queryItems.append(URLQueryItem(name: "org_id", value: orgId))
            }

            let response: ChannelsResponse = try await api.get("/channels", queryItems: queryItems.isEmpty ? nil : queryItems)

            // When fetching for a specific org, merge with existing channels
            if let orgId = orgId {
                // Remove old channels for this org, add new ones
                channels.removeAll { $0.orgId == orgId }
                channels.append(contentsOf: response.channels)
            } else {
                channels = response.channels
            }

            // Update total unread count
            totalUnreadCount = channels.reduce(0) { $0 + $1.unreadCount }
        } catch {
            self.error = error.localizedDescription
        }

        isLoadingChannels = false
    }

    /// Creates a new channel
    @MainActor
    func createChannel(in orgId: String, name: String, description: String?, type: ChannelType, eventId: String? = nil) async throws -> Channel {
        let request = CreateChannelRequest(
            orgId: orgId,
            name: name,
            description: description,
            type: type.rawValue,
            eventId: eventId
        )

        let channel: Channel = try await api.post("/channels", body: request)
        channels.insert(channel, at: 0)
        return channel
    }

    /// Gets or creates a DM channel with another user
    @MainActor
    func getOrCreateDM(with userId: String) async throws -> Channel {
        let request = GetOrCreateDMRequest(userId: userId)
        let response: DMChannelResponse = try await api.post("/channels/dm", body: request)

        // Fetch the full channel details
        let channel: Channel = try await api.get("/channels/\(response.channelId)")

        // Add to channels if not present
        if !channels.contains(where: { $0.id == channel.id }) {
            channels.insert(channel, at: 0)
        }

        return channel
    }

    /// Marks a channel as read
    @MainActor
    func markChannelRead(_ channelId: String) async {
        do {
            let _: MessageResponse = try await api.post("/channels/\(channelId)/read", body: EmptyRequest())

            // Update local state
            if let index = channels.firstIndex(where: { $0.id == channelId }) {
                channels[index].unreadCount = 0
            }
            totalUnreadCount = channels.reduce(0) { $0 + $1.unreadCount }
        } catch {
            print("Failed to mark channel as read: \(error)")
        }
    }

    /// Leaves a channel
    @MainActor
    func leaveChannel(_ channelId: String) async throws {
        guard let userId = SecureStorage.shared.userID else { return }
        let _: MessageResponse = try await api.delete("/channels/\(channelId)/members/\(userId)")
        channels.removeAll { $0.id == channelId }
        if activeChannel?.id == channelId {
            activeChannel = nil
        }
    }

    // MARK: - Navigation Helpers

    /// Selects an organization and loads its channels
    @MainActor
    func selectOrganization(_ org: Organization?) async {
        activeOrganization = org
        if let org = org {
            await fetchChannels(forOrg: org.id)
        } else {
            await fetchChannels()
        }
    }

    /// Selects a channel and marks it as read
    @MainActor
    func selectChannel(_ channel: Channel?) async {
        activeChannel = channel
        if let channel = channel {
            await markChannelRead(channel.id)
        }
    }

    // MARK: - Channels By Organization

    /// Returns channels grouped by organization
    var channelsByOrg: [String: [Channel]] {
        Dictionary(grouping: channels.filter { $0.type != .dm && $0.type != .event && $0.orgId != nil }) { $0.orgId ?? "" }
    }

    /// Returns DM channels
    var dmChannels: [Channel] {
        channels.filter { $0.type == .dm }
    }

    /// Returns event channels
    var eventChannels: [Channel] {
        channels.filter { $0.type == .event }
    }

    // MARK: - Governance

    /// Fetches governance info for an organization
    @MainActor
    func getGovernanceInfo(orgId: String) async throws -> OrgGovernanceInfo {
        return try await api.get("/orgs/\(orgId)/governance")
    }

    /// Promotes a member to admin
    @MainActor
    func promoteToAdmin(orgId: String, userId: String) async throws {
        let request = ["user_id": userId]
        let _: MessageResponse = try await api.post("/orgs/\(orgId)/promote", body: request)
    }

    /// Demotes an admin to member
    @MainActor
    func demoteFromAdmin(orgId: String, userId: String) async throws {
        let _: MessageResponse = try await api.delete("/orgs/\(orgId)/admins/\(userId)")
    }

    /// Requests admin transfer to another user
    @MainActor
    func requestAdminTransfer(orgId: String, toUserId: String) async throws -> AdminTransferResponse {
        let request = ["to_user_id": toUserId]
        return try await api.post("/orgs/\(orgId)/transfer", body: request)
    }

    /// Responds to an admin transfer request
    @MainActor
    func respondToTransfer(requestId: String, accept: Bool) async throws {
        let request = ["accept": accept]
        let _: MessageResponse = try await api.post("/admin-transfers/\(requestId)/respond", body: request)
    }

    /// Archives an organization (soft delete)
    @MainActor
    func archiveOrganization(id: String) async throws {
        let _: MessageResponse = try await api.post("/orgs/\(id)/archive", body: EmptyRequest())
        // Remove from local list
        organizations.removeAll { $0.id == id }
    }

    /// Unarchives an organization
    @MainActor
    func unarchiveOrganization(id: String) async throws {
        let _: MessageResponse = try await api.post("/orgs/\(id)/unarchive", body: EmptyRequest())
        await fetchOrganizations()
    }

    /// Deletes an organization (with safeguards)
    @MainActor
    func deleteOrganization(id: String) async throws {
        let _: MessageResponse = try await api.delete("/orgs/\(id)")
        organizations.removeAll { $0.id == id }
    }

    /// Hides a conversation from view
    @MainActor
    func hideConversation(channelId: String) async throws {
        let _: MessageResponse = try await api.post("/channels/\(channelId)/hide", body: EmptyRequest())
        channels.removeAll { $0.id == channelId }
    }

    /// Unhides a conversation
    @MainActor
    func unhideConversation(channelId: String) async throws {
        let _: MessageResponse = try await api.post("/channels/\(channelId)/unhide", body: EmptyRequest())
        await fetchChannels()
    }

    /// Archives a channel
    @MainActor
    func archiveChannel(channelId: String) async throws {
        let _: MessageResponse = try await api.post("/channels/\(channelId)/archive", body: EmptyRequest())
        channels.removeAll { $0.id == channelId }
    }

    /// Unarchives a channel
    @MainActor
    func unarchiveChannel(channelId: String) async throws {
        let _: MessageResponse = try await api.post("/channels/\(channelId)/unarchive", body: EmptyRequest())
        await fetchChannels()
    }
}

// MARK: - Helper Types

private struct EmptyRequest: Encodable {}
