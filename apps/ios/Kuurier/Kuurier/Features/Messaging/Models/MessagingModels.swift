import Foundation

// MARK: - Organizations

/// Represents an organization (top-level grouping for channels)
struct Organization: Identifiable, Codable {
    let id: String
    let name: String
    let description: String?
    let avatarUrl: String?
    let isPublic: Bool
    let createdBy: String
    let createdAt: Date
    var memberCount: Int
    var role: String? // Current user's role (admin, moderator, member)

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case avatarUrl = "avatar_url"
        case isPublic = "is_public"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case memberCount = "member_count"
        case role
    }
}

/// Request to create an organization
struct CreateOrganizationRequest: Encodable {
    let name: String
    let description: String?
    let isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case name, description
        case isPublic = "is_public"
    }
}

// MARK: - Channels

/// Channel type enumeration
enum ChannelType: String, Codable {
    case publicChannel = "public"
    case privateChannel = "private"
    case dm = "dm"
    case event = "event"
}

/// Represents a chat channel
struct Channel: Identifiable, Codable, Hashable {
    let id: String
    let orgId: String?
    let name: String?
    let description: String?
    let type: ChannelType
    let eventId: String?
    let createdBy: String
    let createdAt: Date
    var memberCount: Int
    var unreadCount: Int
    var lastActivity: Date?
    var otherUserId: String? // For DMs

    enum CodingKeys: String, CodingKey {
        case id
        case orgId = "org_id"
        case name, description, type
        case eventId = "event_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case memberCount = "member_count"
        case unreadCount = "unread_count"
        case lastActivity = "last_activity"
        case otherUserId = "other_user_id"
    }

    /// Display name for the channel
    var displayName: String {
        if type == .dm {
            return otherUserId ?? "Direct Message"
        }
        return name ?? "Unnamed Channel"
    }
}

/// Request to create a channel
struct CreateChannelRequest: Encodable {
    let orgId: String
    let name: String
    let description: String?
    let type: String
    let eventId: String?

    enum CodingKeys: String, CodingKey {
        case orgId = "org_id"
        case name, description, type
        case eventId = "event_id"
    }
}

/// Request to create/get a DM channel
struct GetOrCreateDMRequest: Encodable {
    let userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

/// Response for DM channel creation
struct DMChannelResponse: Decodable {
    let channelId: String
    let otherUserId: String

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case otherUserId = "other_user_id"
    }
}

// MARK: - Messages

/// Message type enumeration
enum MessageType: String, Codable {
    case text
    case media
    case system
}

/// Represents an encrypted message
struct Message: Identifiable, Codable {
    let id: String
    let channelId: String
    let senderId: String
    var ciphertext: Data // Encrypted content
    let messageType: MessageType
    let replyToId: String?
    let createdAt: Date
    var editedAt: Date?

    // Decrypted content (populated client-side)
    var decryptedContent: String?

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case senderId = "sender_id"
        case ciphertext
        case messageType = "message_type"
        case replyToId = "reply_to_id"
        case createdAt = "created_at"
        case editedAt = "edited_at"
    }

    /// Returns true if the message is from the current user
    func isFromCurrentUser(currentUserId: String) -> Bool {
        return senderId == currentUserId
    }
}

/// Request to send a message
struct SendMessageRequest: Encodable {
    let channelId: String
    let ciphertext: Data
    let messageType: String
    let replyToId: String?

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case ciphertext
        case messageType = "message_type"
        case replyToId = "reply_to_id"
    }
}

// MARK: - API Responses

/// Response for organization list
struct OrganizationsResponse: Decodable {
    let organizations: [Organization]
}

/// Response for channel list
struct ChannelsResponse: Decodable {
    let channels: [Channel]
}

/// Response for message list
struct MessagesResponse: Decodable {
    let messages: [Message]
}

// MARK: - Member Types

/// Organization member role
enum OrgMemberRole: String, Codable {
    case admin
    case moderator
    case member
}

/// Channel member info
struct ChannelMember: Identifiable, Codable {
    let id: String // user_id
    let role: String
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case role
        case joinedAt = "joined_at"
    }
}

// MARK: - WebSocket Events

/// WebSocket event types
enum WebSocketEventType: String, Codable {
    // Client -> Server
    case messageSend = "message.send"
    case messageRead = "message.read"
    case typingStart = "typing.start"
    case typingStop = "typing.stop"
    case presenceUpdate = "presence.update"

    // Server -> Client
    case messageNew = "message.new"
    case messageEdited = "message.edited"
    case messageDeleted = "message.deleted"
    case typingUpdate = "typing.update"
    case channelUpdated = "channel.updated"
}

/// WebSocket message envelope
struct WebSocketMessage: Codable {
    let type: String
    let channelId: String?
    let payload: Data? // JSON-encoded payload

    enum CodingKeys: String, CodingKey {
        case type
        case channelId = "channel_id"
        case payload
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: Identifiable {
    let id: String // channelId + userId
    let channelId: String
    let userId: String
    let startedAt: Date

    var isExpired: Bool {
        return Date().timeIntervalSince(startedAt) > 5 // 5 second timeout
    }
}

// MARK: - Presence

struct UserPresence {
    let userId: String
    var isOnline: Bool
    var lastSeen: Date?
}
