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
    let media: [PostMedia]?
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
}

struct GenerateInviteResponse: Codable {
    let id: String
    let code: String
    let expiresAt: Date
    let message: String
}
