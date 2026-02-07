package com.kuurier.app.core.network

import com.kuurier.app.core.models.*
import retrofit2.http.*

interface KuurierApi {

    // Auth
    @POST("auth/register")
    suspend fun register(@Body request: RegisterRequest): ChallengeResponse

    @POST("auth/verify")
    suspend fun verify(@Body request: VerifyRequest): AuthResponse

    // Feed
    @GET("feed")
    suspend fun getFeed(
        @Query("page") page: Int = 1,
        @Query("per_page") perPage: Int = 20
    ): List<FeedPost>

    @POST("feed/posts")
    suspend fun createPost(@Body request: CreatePostRequest): MessageResponse

    @GET("topics")
    suspend fun getTopics(): List<Topic>

    // Subscriptions
    @GET("subscriptions")
    suspend fun getSubscriptions(): List<Subscription>

    @POST("subscriptions")
    suspend fun createSubscription(@Body request: CreateSubscriptionRequest): MessageResponse

    @DELETE("subscriptions/{id}")
    suspend fun deleteSubscription(@Path("id") id: String): MessageResponse

    // Events
    @GET("events")
    suspend fun getEvents(
        @Query("page") page: Int = 1,
        @Query("per_page") perPage: Int = 20
    ): List<Event>

    @POST("events")
    suspend fun createEvent(@Body request: CreateEventRequest): MessageResponse

    @POST("events/{id}/rsvp")
    suspend fun rsvpEvent(@Path("id") id: String): MessageResponse

    @GET("events/nearby")
    suspend fun getNearbyEvents(
        @Query("latitude") latitude: Double,
        @Query("longitude") longitude: Double,
        @Query("radius") radius: Double = 50.0
    ): List<Event>

    // Alerts
    @GET("alerts")
    suspend fun getAlerts(): List<Alert>

    @POST("alerts")
    suspend fun createAlert(@Body request: CreateAlertRequest): MessageResponse

    @POST("alerts/{id}/respond")
    suspend fun respondToAlert(@Path("id") id: String): MessageResponse

    @GET("alerts/nearby")
    suspend fun getNearbyAlerts(
        @Query("latitude") latitude: Double,
        @Query("longitude") longitude: Double,
        @Query("radius") radius: Double = 50.0
    ): List<Alert>

    // Push Notifications
    @POST("push/token")
    suspend fun registerPushToken(@Body request: PushTokenRequest): MessageResponse

    @DELETE("push/token")
    suspend fun unregisterPushToken(@Body request: PushTokenRequest): MessageResponse

    @GET("push/quiet-hours")
    suspend fun getQuietHours(): QuietHours

    @PUT("push/quiet-hours")
    suspend fun setQuietHours(@Body request: QuietHoursRequest): MessageResponse

    @DELETE("push/quiet-hours")
    suspend fun deleteQuietHours(): MessageResponse

    // Messaging
    @GET("organizations")
    suspend fun getOrganizations(): List<Organization>

    @GET("organizations/{id}/channels")
    suspend fun getChannels(@Path("id") orgId: String): List<Channel>

    @GET("channels/{id}/messages")
    suspend fun getMessages(
        @Path("id") channelId: String,
        @Query("before") before: String? = null,
        @Query("limit") limit: Int = 50
    ): List<Message>

    // Map
    @GET("map/heatmap")
    suspend fun getHeatmap(): Any

    @GET("map/clusters")
    suspend fun getClusters(
        @Query("min_lat") minLat: Double,
        @Query("min_lng") minLng: Double,
        @Query("max_lat") maxLat: Double,
        @Query("max_lng") maxLng: Double,
        @Query("zoom") zoom: Int
    ): Any

    // User
    @GET("users/me")
    suspend fun getProfile(): UserProfile
}
