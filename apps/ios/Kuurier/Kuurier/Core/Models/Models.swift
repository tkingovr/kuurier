import Foundation
import CoreLocation

// MARK: - User & Auth

struct User: Codable, Identifiable {
    let id: String
    let trustScore: Int
    let isVerified: Bool
    let createdAt: Date
    let vouchCount: Int?
}

struct AuthChallenge: Codable {
    let userId: String
    let challenge: String
    let expiresAt: Int64?
}

struct AuthToken: Codable {
    let token: String
    let expiresAt: Int64
}

// MARK: - Posts & Feed

struct Post: Codable, Identifiable {
    let id: String
    let authorId: String
    let content: String
    let sourceType: SourceType
    let location: Location?
    let locationName: String?
    let urgency: Int
    let createdAt: Date
    let verificationScore: Int
}

enum SourceType: String, Codable {
    case firsthand
    case aggregated
    case mainstream
}

struct Location: Codable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Topics & Subscriptions

struct Topic: Codable, Identifiable {
    let id: String
    let slug: String
    let name: String
    let icon: String?
}

struct Subscription: Codable, Identifiable {
    let id: String
    let topic: Topic?
    let location: Location?
    let radiusMeters: Int?
    let minUrgency: Int
    let digestMode: DigestMode
    let isActive: Bool
}

enum DigestMode: String, Codable {
    case realtime
    case daily
    case weekly
}

// MARK: - Events

struct Event: Codable, Identifiable {
    let id: String
    let organizerId: String
    let title: String
    let description: String?
    let eventType: EventType
    let location: Location
    let locationName: String?
    let startsAt: Date
    let endsAt: Date?
    let isCancelled: Bool?
    let rsvpCount: Int?
    let userRsvp: RSVPStatus?
    let distanceMeters: Int?
}

enum EventType: String, Codable {
    case protest
    case strike
    case fundraiser
    case mutualAid = "mutual_aid"
    case meeting
    case other
}

enum RSVPStatus: String, Codable {
    case going
    case interested
    case notGoing = "not_going"
}

// MARK: - Alerts (SOS)

struct Alert: Codable, Identifiable {
    let id: String
    let authorId: String
    let title: String
    let description: String?
    let severity: Int
    let severityLabel: String?
    let location: Location
    let locationName: String?
    let radiusMeters: Int
    let status: AlertStatus
    let createdAt: Date
    let resolvedAt: Date?
    let responseCount: Int?
    let responses: [AlertResponse]?
    let userResponse: AlertResponseStatus?
    let distanceMeters: Int?
}

enum AlertStatus: String, Codable {
    case active
    case resolved
    case falseAlarm = "false_alarm"
}

struct AlertResponse: Codable {
    let userId: String
    let status: AlertResponseStatus
    let etaMinutes: Int?
    let createdAt: Date
}

enum AlertResponseStatus: String, Codable {
    case acknowledged
    case enRoute = "en_route"
    case arrived
    case unable
}

// MARK: - Map

struct HeatmapCell: Codable {
    let latitude: Double
    let longitude: Double
    let count: Int
    let maxUrgency: Int
    let heatLevel: String
}

struct MapCluster: Codable {
    let type: String // "cluster" or "post"
    let latitude: Double
    let longitude: Double
    let count: Int?
    let maxUrgency: Int?
    // Post-specific fields
    let id: String?
    let content: String?
    let sourceType: String?
    let urgency: Int?
    let createdAt: Date?
}

// MARK: - API Responses

struct FeedResponse: Codable {
    let posts: [Post]
    let limit: Int
    let offset: Int
}

struct EventsResponse: Codable {
    let events: [Event]
    let limit: Int
    let offset: Int
}

struct AlertsResponse: Codable {
    let alerts: [Alert]
}

struct TopicsResponse: Codable {
    let topics: [Topic]
}

struct SubscriptionsResponse: Codable {
    let subscriptions: [Subscription]
}

struct HeatmapResponse: Codable {
    let cells: [HeatmapCell]
    let gridSize: String
}

struct ClustersResponse: Codable {
    let markers: [MapCluster]
    let clustered: Bool
}

struct NearbyPostsResponse: Codable {
    let posts: [Post]
    let center: Location
    let radius: Int
}

struct NearbyEventsResponse: Codable {
    let events: [Event]
    let center: Location
    let radius: Int
}

struct NearbyAlertsResponse: Codable {
    let alerts: [Alert]
    let center: Location
}

struct MessageResponse: Codable {
    let message: String
    let id: String?
}

// MARK: - Invites

struct InviteCode: Codable, Identifiable {
    let id: String
    let code: String
    let inviterId: String
    let inviteeId: String?
    let createdAt: Date
    let expiresAt: Date
    let usedAt: Date?
    let status: InviteStatus

    enum CodingKeys: String, CodingKey {
        case id, code, status
        case inviterId = "inviter_id"
        case inviteeId = "invitee_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case usedAt = "used_at"
    }
}

enum InviteStatus: String, Codable {
    case active
    case used
    case expired
}

struct InvitesResponse: Codable {
    let invites: [InviteCode]
    let totalAllowance: Int
    let usedCount: Int
    let activeCount: Int
    let availableToMake: Int

    enum CodingKeys: String, CodingKey {
        case invites
        case totalAllowance = "total_allowance"
        case usedCount = "used_count"
        case activeCount = "active_count"
        case availableToMake = "available_to_make"
    }
}

struct GenerateInviteResponse: Codable {
    let id: String
    let code: String
    let expiresAt: Date
    let message: String

    enum CodingKeys: String, CodingKey {
        case id, code, message
        case expiresAt = "expires_at"
    }
}
