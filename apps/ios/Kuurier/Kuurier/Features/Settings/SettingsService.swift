import Foundation
import Combine

/// Service for managing user settings (vouches, subscriptions, quiet hours)
final class SettingsService: ObservableObject {

    static let shared = SettingsService()

    // MARK: - Published State

    // Vouches
    @Published var vouchesReceived: [Vouch] = []
    @Published var vouchesGiven: [VouchGiven] = []
    @Published var isLoadingVouches = false

    // Topics
    @Published var topics: [Topic] = []
    @Published var subscriptions: [Subscription] = []
    @Published var isLoadingTopics = false
    @Published var isLoadingSubscriptions = false

    // Quiet Hours
    @Published var quietHours: QuietHours?
    @Published var isLoadingQuietHours = false

    @Published var error: String?

    private let api = APIClient.shared

    private init() {}

    // MARK: - Vouches

    /// Fetches vouches received and given
    @MainActor
    func fetchVouches() async {
        guard !isLoadingVouches else { return }

        isLoadingVouches = true
        error = nil

        do {
            let response: VouchesResponse = try await api.get("/vouches")
            vouchesReceived = response.received ?? []
            vouchesGiven = response.given ?? []
            isLoadingVouches = false
        } catch {
            self.error = error.localizedDescription
            isLoadingVouches = false
        }
    }

    /// Vouch for another user
    @MainActor
    func vouchForUser(userId: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.post("/vouch/\(userId)", body: EmptyRequest())
            await fetchVouches()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Topics & Subscriptions

    /// Fetches available topics
    @MainActor
    func fetchTopics() async {
        guard !isLoadingTopics else { return }

        isLoadingTopics = true
        error = nil

        do {
            let response: TopicsResponse = try await api.get("/topics")
            topics = response.topics
            isLoadingTopics = false
        } catch {
            self.error = error.localizedDescription
            isLoadingTopics = false
        }
    }

    /// Fetches user's subscriptions
    @MainActor
    func fetchSubscriptions() async {
        guard !isLoadingSubscriptions else { return }

        isLoadingSubscriptions = true
        error = nil

        do {
            let response: SubscriptionsResponse = try await api.get("/subscriptions")
            subscriptions = response.subscriptions
            isLoadingSubscriptions = false
        } catch {
            self.error = error.localizedDescription
            isLoadingSubscriptions = false
        }
    }

    /// Creates a new subscription
    @MainActor
    func createSubscription(topicId: String?, location: Location?, radiusMeters: Int?, minUrgency: Int, digestMode: DigestMode) async -> Bool {
        do {
            let request = CreateSubscriptionRequest(
                topicId: topicId,
                latitude: location?.latitude,
                longitude: location?.longitude,
                radiusMeters: radiusMeters,
                minUrgency: minUrgency,
                digestMode: digestMode.rawValue
            )
            let _: MessageResponse = try await api.post("/subscriptions", body: request)
            await fetchSubscriptions()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Updates a subscription
    @MainActor
    func updateSubscription(id: String, minUrgency: Int, digestMode: DigestMode, isActive: Bool) async -> Bool {
        do {
            let request = UpdateSubscriptionRequest(
                minUrgency: minUrgency,
                digestMode: digestMode.rawValue,
                isActive: isActive
            )
            let _: MessageResponse = try await api.put("/subscriptions/\(id)", body: request)
            await fetchSubscriptions()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Deletes a subscription
    @MainActor
    func deleteSubscription(id: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.delete("/subscriptions/\(id)")
            subscriptions.removeAll { $0.id == id }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Quiet Hours

    /// Fetches quiet hours settings
    @MainActor
    func fetchQuietHours() async {
        guard !isLoadingQuietHours else { return }

        isLoadingQuietHours = true
        error = nil

        do {
            let response: QuietHours = try await api.get("/push/quiet-hours")
            quietHours = response
            isLoadingQuietHours = false
        } catch {
            self.error = error.localizedDescription
            isLoadingQuietHours = false
        }
    }

    /// Saves quiet hours settings
    @MainActor
    func saveQuietHours(startTime: String, endTime: String, timezone: String, allowEmergency: Bool, isActive: Bool) async -> Bool {
        do {
            let request = QuietHoursRequest(
                startTime: startTime,
                endTime: endTime,
                timezone: timezone,
                allowEmergency: allowEmergency,
                isActive: isActive
            )
            let _: MessageResponse = try await api.put("/push/quiet-hours", body: request)
            await fetchQuietHours()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Deletes quiet hours settings
    @MainActor
    func deleteQuietHours() async -> Bool {
        do {
            let _: MessageResponse = try await api.delete("/push/quiet-hours")
            quietHours = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - User Profiles

    /// Fetches another user's profile
    @MainActor
    func fetchUserProfile(userId: String) async -> UserProfile? {
        do {
            let profile: UserProfile = try await api.get("/users/\(userId)")
            return profile
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Searches for users by ID prefix
    @MainActor
    func searchUsers(query: String, limit: Int = 20) async -> [UserProfile] {
        guard query.count >= 3 else { return [] }

        do {
            let response: UserSearchResponse = try await api.get("/users", queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit))
            ])
            return response.users
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }
}

// MARK: - Request Types

private struct EmptyRequest: Encodable {}

private struct CreateSubscriptionRequest: Encodable {
    let topicId: String?
    let latitude: Double?
    let longitude: Double?
    let radiusMeters: Int?
    let minUrgency: Int
    let digestMode: String

    enum CodingKeys: String, CodingKey {
        case topicId = "topic_id"
        case latitude
        case longitude
        case radiusMeters = "radius_meters"
        case minUrgency = "min_urgency"
        case digestMode = "digest_mode"
    }
}

private struct UpdateSubscriptionRequest: Encodable {
    let minUrgency: Int
    let digestMode: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case minUrgency = "min_urgency"
        case digestMode = "digest_mode"
        case isActive = "is_active"
    }
}
