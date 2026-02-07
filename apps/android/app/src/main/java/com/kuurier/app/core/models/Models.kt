package com.kuurier.app.core.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// MARK: - Auth

@Serializable
data class RegisterRequest(
    @SerialName("public_key") val publicKey: String,
    @SerialName("display_name") val displayName: String
)

@Serializable
data class ChallengeResponse(
    val challenge: String,
    @SerialName("user_id") val userId: String
)

@Serializable
data class VerifyRequest(
    @SerialName("user_id") val userId: String,
    val signature: String
)

@Serializable
data class AuthResponse(
    val token: String,
    @SerialName("user_id") val userId: String
)

// MARK: - User

@Serializable
data class UserProfile(
    val id: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("trust_score") val trustScore: Int = 0,
    @SerialName("is_verified") val isVerified: Boolean = false,
    @SerialName("created_at") val createdAt: String? = null
)

// MARK: - Feed

@Serializable
data class FeedPost(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("author_name") val authorName: String = "",
    val content: String,
    val topics: List<String> = emptyList(),
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("location_name") val locationName: String? = null,
    @SerialName("media_url") val mediaUrl: String? = null,
    @SerialName("like_count") val likeCount: Int = 0,
    @SerialName("comment_count") val commentCount: Int = 0,
    @SerialName("created_at") val createdAt: String = ""
)

@Serializable
data class CreatePostRequest(
    val content: String,
    val topics: List<String> = emptyList(),
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("location_name") val locationName: String? = null,
    @SerialName("media_url") val mediaUrl: String? = null
)

@Serializable
data class Topic(
    val id: String,
    val name: String,
    val description: String = "",
    @SerialName("post_count") val postCount: Int = 0
)

// MARK: - Subscriptions

@Serializable
data class Subscription(
    val id: String,
    val type: String,
    @SerialName("topic_id") val topicId: String? = null,
    @SerialName("topic_name") val topicName: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val radius: Double? = null,
    @SerialName("location_name") val locationName: String? = null
)

@Serializable
data class CreateSubscriptionRequest(
    val type: String,
    @SerialName("topic_id") val topicId: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val radius: Double? = null,
    @SerialName("location_name") val locationName: String? = null
)

// MARK: - Events

@Serializable
data class Event(
    val id: String,
    val title: String,
    val description: String,
    @SerialName("organizer_id") val organizerId: String,
    @SerialName("organizer_name") val organizerName: String = "",
    @SerialName("start_time") val startTime: String,
    @SerialName("end_time") val endTime: String? = null,
    val latitude: Double,
    val longitude: Double,
    @SerialName("location_name") val locationName: String = "",
    @SerialName("rsvp_count") val rsvpCount: Int = 0,
    @SerialName("has_rsvp") val hasRsvp: Boolean = false,
    @SerialName("created_at") val createdAt: String = ""
)

@Serializable
data class CreateEventRequest(
    val title: String,
    val description: String,
    @SerialName("start_time") val startTime: String,
    @SerialName("end_time") val endTime: String? = null,
    val latitude: Double,
    val longitude: Double,
    @SerialName("location_name") val locationName: String
)

// MARK: - Alerts

@Serializable
data class Alert(
    val id: String,
    @SerialName("creator_id") val creatorId: String,
    @SerialName("creator_name") val creatorName: String = "",
    val message: String,
    val latitude: Double,
    val longitude: Double,
    @SerialName("location_name") val locationName: String = "",
    @SerialName("responder_count") val responderCount: Int = 0,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("created_at") val createdAt: String = ""
)

@Serializable
data class CreateAlertRequest(
    val message: String,
    val latitude: Double,
    val longitude: Double,
    @SerialName("location_name") val locationName: String
)

// MARK: - Push Notifications

@Serializable
data class PushTokenRequest(
    val token: String,
    val platform: String
)

@Serializable
data class QuietHours(
    val configured: Boolean,
    @SerialName("start_time") val startTime: String,
    @SerialName("end_time") val endTime: String,
    val timezone: String,
    @SerialName("allow_emergency") val allowEmergency: Boolean,
    @SerialName("is_active") val isActive: Boolean
)

@Serializable
data class QuietHoursRequest(
    @SerialName("start_time") val startTime: String,
    @SerialName("end_time") val endTime: String,
    val timezone: String,
    @SerialName("allow_emergency") val allowEmergency: Boolean,
    @SerialName("is_active") val isActive: Boolean
)

// MARK: - Messaging

@Serializable
data class Organization(
    val id: String,
    val name: String,
    val description: String = "",
    @SerialName("member_count") val memberCount: Int = 0,
    @SerialName("is_member") val isMember: Boolean = false
)

@Serializable
data class Channel(
    val id: String,
    val name: String,
    @SerialName("organization_id") val organizationId: String,
    val description: String = ""
)

@Serializable
data class Message(
    val id: String,
    @SerialName("channel_id") val channelId: String,
    @SerialName("sender_id") val senderId: String,
    @SerialName("sender_name") val senderName: String = "",
    val content: String,
    @SerialName("created_at") val createdAt: String = ""
)

// MARK: - Common

@Serializable
data class MessageResponse(
    val message: String,
    val id: String? = null
)

@Serializable
data class PaginatedResponse<T>(
    val data: List<T>,
    val total: Int = 0,
    val page: Int = 1,
    @SerialName("per_page") val perPage: Int = 20
)
