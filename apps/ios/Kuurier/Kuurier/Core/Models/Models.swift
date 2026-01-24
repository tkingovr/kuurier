import Foundation
import CoreLocation
import UIKit

// MARK: - User & Auth

struct User: Codable, Identifiable {
    let id: String
    let trustScore: Int
    let isVerified: Bool
    let createdAt: Date
    let vouchCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case trustScore = "trust_score"
        case isVerified = "is_verified"
        case createdAt = "created_at"
        case vouchCount = "vouch_count"
    }
}

struct AuthChallenge: Codable {
    let userId: String
    let challenge: String
    let trustScore: Int?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case challenge
        case trustScore = "trust_score"
    }
}

struct AuthToken: Codable {
    let token: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
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
    let media: [PostMedia]?

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case content
        case sourceType = "source_type"
        case location
        case locationName = "location_name"
        case urgency
        case createdAt = "created_at"
        case verificationScore = "verification_score"
        case media
    }
}

struct PostMedia: Codable, Identifiable {
    let id: String
    let url: String
    let type: MediaType

    enum MediaType: String, Codable {
        case image
        case video
    }
}

// MARK: - Media Selection & Upload

/// Represents a locally selected media item before upload
struct SelectedMediaItem: Identifiable {
    let id: UUID
    let data: Data
    let thumbnail: UIImage?
    let type: SelectedMediaType
    let originalFilename: String?

    enum SelectedMediaType {
        case image
        case video

        var mimeType: String {
            switch self {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            }
        }

        var apiValue: String {
            switch self {
            case .image: return "image"
            case .video: return "video"
            }
        }
    }

    init(data: Data, thumbnail: UIImage?, type: SelectedMediaType, originalFilename: String? = nil) {
        self.id = UUID()
        self.data = data
        self.thumbnail = thumbnail
        self.type = type
        self.originalFilename = originalFilename
    }
}

struct MediaUploadResponse: Decodable {
    let url: String
    let mediaType: String
    let size: Int64
    let filename: String

    enum CodingKeys: String, CodingKey {
        case url
        case mediaType = "media_type"
        case size
        case filename
    }
}

struct MediaAttachResponse: Decodable {
    let id: String
    let postId: String
    let mediaUrl: String
    let mediaType: String

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case mediaUrl = "media_url"
        case mediaType = "media_type"
    }
}

enum SourceType: String, Codable {
    case firsthand
    case aggregated
    case mainstream
}

struct Location: Codable {
    let latitude: Double
    let longitude: Double
    let name: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // Allow init without name for backwards compatibility
    init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
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

    enum CodingKeys: String, CodingKey {
        case id
        case topic
        case location
        case radiusMeters = "radius_meters"
        case minUrgency = "min_urgency"
        case digestMode = "digest_mode"
        case isActive = "is_active"
    }
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
    let location: Location?              // May be nil if location is hidden
    let locationName: String?
    let locationArea: String?            // General area when exact location hidden
    let locationVisibility: LocationVisibility
    let locationRevealed: Bool           // Whether location is currently visible to user
    let locationRevealAt: Date?          // For timed visibility: when location will be revealed
    let locationHint: String?            // Hint like "RSVP to see exact location"
    let startsAt: Date
    let endsAt: Date?
    let isCancelled: Bool?
    let rsvpCount: Int?
    let userRsvp: RSVPStatus?
    let distanceMeters: Int?
    let channelId: String?               // Event chat channel ID
    let isChannelMember: Bool?           // Whether user is member of event channel

    enum CodingKeys: String, CodingKey {
        case id
        case organizerId = "organizer_id"
        case title
        case description
        case eventType = "event_type"
        case location
        case locationName = "location_name"
        case locationArea = "location_area"
        case locationVisibility = "location_visibility"
        case locationRevealed = "location_revealed"
        case locationRevealAt = "location_reveal_at"
        case locationHint = "location_hint"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isCancelled = "is_cancelled"
        case rsvpCount = "rsvp_count"
        case userRsvp = "user_rsvp"
        case distanceMeters = "distance_meters"
        case channelId = "channel_id"
        case isChannelMember = "is_channel_member"
    }
}

enum EventType: String, Codable, CaseIterable {
    case protest
    case strike
    case fundraiser
    case mutualAid = "mutual_aid"
    case meeting
    case other

    var displayName: String {
        switch self {
        case .protest: return "Protest"
        case .strike: return "Strike"
        case .fundraiser: return "Fundraiser"
        case .mutualAid: return "Mutual Aid"
        case .meeting: return "Meeting"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .protest: return "megaphone.fill"
        case .strike: return "hand.raised.fill"
        case .fundraiser: return "heart.fill"
        case .mutualAid: return "hands.sparkles.fill"
        case .meeting: return "person.3.fill"
        case .other: return "calendar"
        }
    }
}

enum LocationVisibility: String, Codable, CaseIterable {
    case `public`   // Always visible, shows on map
    case rsvp       // Only visible after RSVP
    case timed      // Hidden until reveal time

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .rsvp: return "RSVP Only"
        case .timed: return "Reveal Later"
        }
    }

    var description: String {
        switch self {
        case .public: return "Location visible to everyone and shown on map"
        case .rsvp: return "Location revealed only after attendee RSVPs"
        case .timed: return "Location hidden until a set time before event"
        }
    }
}

enum RSVPStatus: String, Codable {
    case going
    case interested
    case notGoing = "not_going"

    var displayName: String {
        switch self {
        case .going: return "Going"
        case .interested: return "Interested"
        case .notGoing: return "Can't Go"
        }
    }
}

// MARK: - News

struct NewsArticle: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let link: String
    let source: String
    let sourceIcon: String
    let publishedAt: Date
    let imageURL: String?
    let category: String
    let location: Location?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case link
        case source
        case sourceIcon = "source_icon"
        case publishedAt = "published_at"
        case imageURL = "image_url"
        case category
        case location
    }
}

struct NewsResponse: Decodable {
    let articles: [NewsArticle]
    let cached: Bool
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

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case title
        case description
        case severity
        case severityLabel = "severity_label"
        case location
        case locationName = "location_name"
        case radiusMeters = "radius_meters"
        case status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case responseCount = "response_count"
        case responses
        case userResponse = "user_response"
        case distanceMeters = "distance_meters"
    }

    /// Returns a human-readable severity label
    var severityDisplayName: String {
        switch severity {
        case 1: return "Awareness"
        case 2: return "Help Needed"
        case 3: return "Emergency"
        default: return "Unknown"
        }
    }

    /// Returns the color for this severity level
    var severityColor: String {
        switch severity {
        case 1: return "yellow"
        case 2: return "orange"
        case 3: return "red"
        default: return "gray"
        }
    }
}

enum AlertStatus: String, Codable {
    case active
    case resolved
    case falseAlarm = "false_alarm"
}

struct AlertResponse: Codable, Identifiable {
    let userId: String
    let status: AlertResponseStatus
    let etaMinutes: Int?
    let createdAt: Date

    var id: String { "\(userId)-\(createdAt.timeIntervalSince1970)" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case etaMinutes = "eta_minutes"
        case createdAt = "created_at"
    }

    /// Returns human-readable status
    var statusDisplayName: String {
        switch status {
        case .acknowledged: return "Acknowledged"
        case .enRoute: return "On the way"
        case .arrived: return "Arrived"
        case .unable: return "Unable to help"
        }
    }

    /// Returns icon for the status
    var statusIcon: String {
        switch status {
        case .acknowledged: return "checkmark.circle"
        case .enRoute: return "figure.walk"
        case .arrived: return "mappin.circle.fill"
        case .unable: return "xmark.circle"
        }
    }
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

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case count
        case maxUrgency = "max_urgency"
        case heatLevel = "heat_level"
    }
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

    enum CodingKeys: String, CodingKey {
        case type
        case latitude
        case longitude
        case count
        case maxUrgency = "max_urgency"
        case id
        case content
        case sourceType = "source_type"
        case urgency
        case createdAt = "created_at"
    }
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

    enum CodingKeys: String, CodingKey {
        case cells
        case gridSize = "grid_size"
    }
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
        case id
        case code
        case inviterId = "inviter_id"
        case inviteeId = "invitee_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case usedAt = "used_at"
        case status
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
        case id
        case code
        case expiresAt = "expires_at"
        case message
    }
}

// MARK: - User Profile

struct UserProfile: Codable, Identifiable {
    let id: String
    let trustScore: Int
    let isVerified: Bool
    let createdAt: Date
    let vouchCount: Int
    let hasVouched: Bool
    let canVouch: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case trustScore = "trust_score"
        case isVerified = "is_verified"
        case createdAt = "created_at"
        case vouchCount = "vouch_count"
        case hasVouched = "has_vouched"
        case canVouch = "can_vouch"
    }
}

struct UserSearchResponse: Codable {
    let users: [UserProfile]
    let query: String
    let count: Int
}

// MARK: - Vouches

struct Vouch: Codable, Identifiable {
    let userId: String
    let createdAt: Date

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "from"
        case createdAt = "created_at"
    }
}

struct VouchGiven: Codable, Identifiable {
    let userId: String
    let createdAt: Date

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "to"
        case createdAt = "created_at"
    }
}

struct VouchesResponse: Codable {
    let received: [Vouch]?
    let given: [VouchGiven]?
}

// MARK: - Quiet Hours

struct QuietHours: Codable {
    let configured: Bool
    let startTime: String
    let endTime: String
    let timezone: String
    let allowEmergency: Bool
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case configured
        case startTime = "start_time"
        case endTime = "end_time"
        case timezone
        case allowEmergency = "allow_emergency"
        case isActive = "is_active"
    }
}

struct QuietHoursRequest: Encodable {
    let startTime: String
    let endTime: String
    let timezone: String
    let allowEmergency: Bool
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case timezone
        case allowEmergency = "allow_emergency"
        case isActive = "is_active"
    }
}
