package api

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/alerts"
	"github.com/kuurier/server/internal/auth"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/events"
	"github.com/kuurier/server/internal/feed"
	"github.com/kuurier/server/internal/geo"
	"github.com/kuurier/server/internal/invites"
	"github.com/kuurier/server/internal/keys"
	"github.com/kuurier/server/internal/media"
	"github.com/kuurier/server/internal/messaging"
	"github.com/kuurier/server/internal/middleware"
	"github.com/kuurier/server/internal/storage"
	"github.com/kuurier/server/internal/websocket"
)

// NewRouter creates and configures the API router
// Returns the router and the WebSocket hub (hub must be Run() in a goroutine)
func NewRouter(cfg *config.Config, db *storage.Postgres, redis *storage.Redis, minio *storage.MinIO) (*gin.Engine, *websocket.Hub) {
	// Set Gin mode based on environment
	if cfg.Environment == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.New()

	// Global middleware
	router.Use(gin.Recovery())
	router.Use(middleware.Logger())
	router.Use(middleware.CORS())
	router.Use(middleware.Security())
	router.Use(middleware.RateLimit(redis))

	// Health check (public)
	router.GET("/health", healthCheck(db, redis))

	// Initialize WebSocket hub
	wsHub := websocket.NewHub(redis)
	wsHandler := websocket.NewHandler(cfg, wsHub)

	// Initialize handlers
	authHandler := auth.NewHandler(cfg, db)
	invitesHandler := invites.NewHandler(cfg, db)
	keysHandler := keys.NewHandler(cfg, db)
	orgHandler := messaging.NewOrganizationHandler(cfg, db)
	channelHandler := messaging.NewChannelHandler(cfg, db)
	messageHandler := messaging.NewMessageHandler(cfg, db)
	feedHandler := feed.NewHandler(cfg, db, redis)
	geoHandler := geo.NewHandler(cfg, db, redis)
	eventsHandler := events.NewHandler(cfg, db, redis)
	alertsHandler := alerts.NewHandler(cfg, db, redis)

	// Media handler (optional - requires MinIO)
	var mediaHandler *media.Handler
	if minio != nil {
		mediaHandler = media.NewHandler(cfg, db, minio)
	}

	// API v1 routes
	v1 := router.Group("/api/v1")
	{
		// Auth routes (public)
		authRoutes := v1.Group("/auth")
		{
			authRoutes.POST("/register", authHandler.Register)
			authRoutes.POST("/challenge", authHandler.Challenge)
			authRoutes.POST("/verify", authHandler.Verify)
		}

		// Invite validation (public - needed before registration)
		v1.GET("/invites/validate/:code", invitesHandler.ValidateInvite)

		// Protected routes
		protected := v1.Group("")
		protected.Use(middleware.Auth(cfg))
		{
			// User routes
			protected.GET("/me", authHandler.GetCurrentUser)
			protected.DELETE("/me", authHandler.DeleteAccount)

			// Vouch system (web of trust)
			protected.POST("/vouch/:user_id", authHandler.Vouch)
			protected.GET("/vouches", authHandler.GetVouches)

			// Invite routes (requires trust 30+)
			inviteRoutes := protected.Group("/invites")
			{
				inviteRoutes.GET("", invitesHandler.ListInvites)
				inviteRoutes.POST("", invitesHandler.GenerateInvite)
				inviteRoutes.DELETE("/:code", invitesHandler.RevokeInvite)
				inviteRoutes.GET("/stats", invitesHandler.GetInviteStats)
			}

			// Signal Protocol key management routes
			keysRoutes := protected.Group("/keys")
			{
				keysRoutes.POST("/bundle", keysHandler.UploadBundle)           // Upload identity + signed pre-key + pre-keys
				keysRoutes.GET("/bundle/:user_id", keysHandler.GetBundle)      // Fetch bundle (consumes pre-key)
				keysRoutes.POST("/prekeys", keysHandler.UploadPreKeys)         // Replenish pre-keys
				keysRoutes.GET("/prekey-count", keysHandler.GetPreKeyCount)    // Check remaining pre-keys
				keysRoutes.PUT("/signed-prekey", keysHandler.UpdateSignedPreKey) // Rotate signed pre-key
			}

			// Organization routes (messaging)
			orgRoutes := protected.Group("/orgs")
			{
				orgRoutes.GET("", orgHandler.ListOrganizations)           // List user's organizations
				orgRoutes.POST("", orgHandler.CreateOrganization)         // Create organization
				orgRoutes.GET("/discover", orgHandler.ListPublicOrganizations) // Discover public orgs
				orgRoutes.GET("/:id", orgHandler.GetOrganization)         // Get organization details
				orgRoutes.PUT("/:id", orgHandler.UpdateOrganization)      // Update organization (admin)
				orgRoutes.DELETE("/:id", orgHandler.DeleteOrganization)   // Delete organization (admin)
				orgRoutes.POST("/:id/join", orgHandler.JoinOrganization)  // Join public org
				orgRoutes.POST("/:id/leave", orgHandler.LeaveOrganization) // Leave organization
			}

			// Channel routes (messaging)
			channelRoutes := protected.Group("/channels")
			{
				channelRoutes.GET("", channelHandler.ListChannels)              // List user's channels
				channelRoutes.POST("", channelHandler.CreateChannel)            // Create channel
				channelRoutes.POST("/dm", channelHandler.GetOrCreateDM)         // Get or create DM
				channelRoutes.GET("/:id", channelHandler.GetChannel)            // Get channel details
				channelRoutes.POST("/:id/members", channelHandler.AddChannelMember)     // Add member
				channelRoutes.DELETE("/:id/members/:user_id", channelHandler.RemoveChannelMember) // Remove member
				channelRoutes.POST("/:id/read", channelHandler.MarkChannelRead) // Mark as read
			}

			// Message routes (E2E encrypted messages)
			messageRoutes := protected.Group("/messages")
			{
				messageRoutes.POST("", messageHandler.SendMessage)                    // Send encrypted message
				messageRoutes.GET("/:channel_id", messageHandler.GetMessages)         // Get message history
				messageRoutes.PUT("/:id", messageHandler.EditMessage)                 // Edit message
				messageRoutes.DELETE("/:id", messageHandler.DeleteMessage)            // Delete message
				messageRoutes.POST("/:id/react", messageHandler.AddReaction)          // Add reaction
				messageRoutes.DELETE("/:id/react", messageHandler.RemoveReaction)     // Remove reaction
			}

			// Feed routes
			feedRoutes := protected.Group("/feed")
			{
				feedRoutes.GET("", feedHandler.GetFeed)
				feedRoutes.POST("/posts", feedHandler.CreatePost)
				feedRoutes.GET("/posts/:id", feedHandler.GetPost)
				feedRoutes.DELETE("/posts/:id", feedHandler.DeletePost)
				feedRoutes.POST("/posts/:id/verify", feedHandler.VerifyPost)
				feedRoutes.POST("/posts/:id/flag", feedHandler.FlagPost)
			}

			// Media routes (only if MinIO is configured)
			if mediaHandler != nil {
				mediaRoutes := protected.Group("/media")
				{
					mediaRoutes.POST("/upload", mediaHandler.Upload)
					mediaRoutes.POST("/attach/:post_id", mediaHandler.AttachToPost)
				}
			}

			// Subscription routes
			subRoutes := protected.Group("/subscriptions")
			{
				subRoutes.GET("", feedHandler.GetSubscriptions)
				subRoutes.POST("", feedHandler.CreateSubscription)
				subRoutes.PUT("/:id", feedHandler.UpdateSubscription)
				subRoutes.DELETE("/:id", feedHandler.DeleteSubscription)
			}

			// Topic routes
			protected.GET("/topics", feedHandler.GetTopics)

			// Map/Geo routes
			geoRoutes := protected.Group("/map")
			{
				geoRoutes.GET("/heatmap", geoHandler.GetHeatmap)
				geoRoutes.GET("/clusters", geoHandler.GetClusters)
				geoRoutes.GET("/nearby", geoHandler.GetNearby)
			}

			// Event routes
			eventRoutes := protected.Group("/events")
			{
				eventRoutes.GET("", eventsHandler.ListEvents)
				eventRoutes.POST("", eventsHandler.CreateEvent)
				eventRoutes.GET("/map", eventsHandler.GetPublicEventsForMap) // Public events for map display
				eventRoutes.GET("/nearby", eventsHandler.GetNearbyEvents)
				eventRoutes.GET("/:id", eventsHandler.GetEvent)
				eventRoutes.PUT("/:id", eventsHandler.UpdateEvent)
				eventRoutes.DELETE("/:id", eventsHandler.DeleteEvent)
				eventRoutes.POST("/:id/rsvp", eventsHandler.RSVP)
				eventRoutes.DELETE("/:id/rsvp", eventsHandler.CancelRSVP)
			}

			// Alert routes (SOS system)
			alertRoutes := protected.Group("/alerts")
			{
				alertRoutes.GET("", alertsHandler.ListAlerts)
				alertRoutes.POST("", alertsHandler.CreateAlert)
				alertRoutes.GET("/:id", alertsHandler.GetAlert)
				alertRoutes.PUT("/:id/status", alertsHandler.UpdateAlertStatus)
				alertRoutes.POST("/:id/respond", alertsHandler.RespondToAlert)
				alertRoutes.GET("/nearby", alertsHandler.GetNearbyAlerts)
			}

			// WebSocket endpoint for real-time messaging
			protected.GET("/ws", wsHandler.HandleConnection)
		}
	}

	return router, wsHub
}

func healthCheck(db *storage.Postgres, redis *storage.Redis) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Check database
		if err := db.HealthCheck(c.Request.Context()); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"status":   "unhealthy",
				"database": "down",
			})
			return
		}

		// Check Redis
		if err := redis.HealthCheck(c.Request.Context()); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"status": "unhealthy",
				"redis":  "down",
			})
			return
		}

		c.JSON(http.StatusOK, gin.H{
			"status":   "healthy",
			"database": "up",
			"redis":    "up",
		})
	}
}
