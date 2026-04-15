package api

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/alerts"
	"github.com/kuurier/server/internal/auth"
	"github.com/kuurier/server/internal/bot"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/devices"
	"github.com/kuurier/server/internal/events"
	"github.com/kuurier/server/internal/feed"
	"github.com/kuurier/server/internal/geo"
	"github.com/kuurier/server/internal/invites"
	"github.com/kuurier/server/internal/keys"
	"github.com/kuurier/server/internal/media"
	"github.com/kuurier/server/internal/messaging"
	"github.com/kuurier/server/internal/middleware"
	"github.com/kuurier/server/internal/news"
	"github.com/kuurier/server/internal/push"
	"github.com/kuurier/server/internal/storage"
	"github.com/kuurier/server/internal/websocket"
)

// BuildInfo identifies the running binary. Deploy scripts compare this
// against the SHA they just built to verify the new code is actually live.
type BuildInfo struct {
	Version   string `json:"version"`
	SHA       string `json:"sha"`
	BuildDate string `json:"built_at"`
}

// NewRouter creates and configures the API router.
// Returns the router and the WebSocket hub (hub must be Run() in a goroutine).
//
// Bot instances are no longer held here — the API process does not run
// bots. Admin-triggered bot runs are forwarded to the worker process
// via Redis (see internal/bot/trigger.go).
func NewRouter(cfg *config.Config, db *storage.Postgres, redis *storage.Redis, minio *storage.MinIO, apns *storage.APNs, build BuildInfo) (*gin.Engine, *websocket.Hub) {
	// Set Gin mode based on environment
	if cfg.Environment == "production" {
		gin.SetMode(gin.ReleaseMode)
	}

	router := gin.New()

	// Global middleware
	router.Use(gin.Recovery())
	router.Use(middleware.MaxBodySize(10 * 1024 * 1024)) // 10MB max request body
	router.Use(middleware.RequestID())                    // must run before Logger so request_id is set
	router.Use(middleware.Logger())
	router.Use(middleware.CORS(cfg.AllowedOrigins))
	router.Use(middleware.Security())
	router.Use(middleware.RateLimit(redis, &middleware.RateLimitConfig{
		RequestsPerMinute: 100,
		FailClosedMode:    cfg.Environment == "production", // Fail closed in production
	}, cfg))

	// Health check (public)
	router.GET("/health", healthCheck(db, redis))

	// Initialize WebSocket hub
	wsHub := websocket.NewHub(redis)
	wsHandler := websocket.NewHandler(cfg, wsHub)

	// Initialize push notification service
	pushService := push.NewService(cfg, db, redis, apns)
	pushHandler := push.NewHandler(cfg, db, pushService)

	// Initialize handlers
	authHandler := auth.NewHandler(cfg, db)
	invitesHandler := invites.NewHandler(cfg, db)
	keysHandler := keys.NewHandler(cfg, db)
	orgHandler := messaging.NewOrganizationHandler(cfg, db)
	channelHandler := messaging.NewChannelHandler(cfg, db)
	messageHandler := messaging.NewMessageHandler(cfg, db)
	groupHandler := messaging.NewGroupHandler(cfg, db)
	governanceHandler := messaging.NewGovernanceHandler(cfg, db)
	newsService := news.NewService()
	feedHandler := feed.NewHandler(cfg, db, redis, newsService)
	newsHandler := news.NewHandler(newsService)
	geoHandler := geo.NewHandler(cfg, db, redis)
	eventsHandler := events.NewHandler(cfg, db, redis)
	alertsHandler := alerts.NewHandler(cfg, db, redis, pushService)
	devicesHandler := devices.NewHandler(cfg, db)

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

		// Build identity (public) — used by deploy scripts to verify
		// the running binary matches the image that was just built.
		v1.GET("/version", func(c *gin.Context) {
			c.JSON(http.StatusOK, build)
		})

		// Invite validation (public - needed before registration)
		v1.GET("/invites/validate/:code", invitesHandler.ValidateInvite)

		// Protected routes
		protected := v1.Group("")
		protected.Use(middleware.Auth(cfg))
		{
			// User routes
			protected.GET("/me", authHandler.GetCurrentUser)
			protected.PUT("/me/display-name", authHandler.SetDisplayName)
			protected.DELETE("/me", authHandler.DeleteAccount)

			// Vouch system (web of trust)
			protected.POST("/vouch/:user_id", authHandler.Vouch)
			protected.GET("/vouches", authHandler.GetVouches)

			// User profile routes
			protected.GET("/users", authHandler.SearchUsers)             // Search users by ID prefix
			protected.GET("/users/:user_id", authHandler.GetUserProfile) // Get specific user profile

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
				keysRoutes.POST("/bundle", keysHandler.UploadBundle)             // Upload identity + signed pre-key + pre-keys
				keysRoutes.GET("/bundle/:user_id", keysHandler.GetBundle)        // Fetch bundle (consumes pre-key)
				keysRoutes.POST("/prekeys", keysHandler.UploadPreKeys)           // Replenish pre-keys
				keysRoutes.GET("/prekey-count", keysHandler.GetPreKeyCount)      // Check remaining pre-keys
				keysRoutes.PUT("/signed-prekey", keysHandler.UpdateSignedPreKey) // Rotate signed pre-key
			}

			// Organization routes (messaging)
			orgRoutes := protected.Group("/orgs")
			{
				orgRoutes.GET("", orgHandler.ListOrganizations)                    // List user's organizations
				orgRoutes.POST("", orgHandler.CreateOrganization)                  // Create organization
				orgRoutes.GET("/discover", orgHandler.ListPublicOrganizations)     // Discover public orgs
				orgRoutes.GET("/:id", orgHandler.GetOrganization)                  // Get organization details
				orgRoutes.PUT("/:id", orgHandler.UpdateOrganization)               // Update organization (admin)
				orgRoutes.DELETE("/:id", governanceHandler.SafeDeleteOrganization) // Delete organization (with safeguards)
				orgRoutes.POST("/:id/join", orgHandler.JoinOrganization)           // Join public org
				orgRoutes.POST("/:id/leave", orgHandler.LeaveOrganization)         // Leave organization

				// Governance routes
				orgRoutes.GET("/:id/governance", governanceHandler.GetOrgGovernanceInfo)    // Get governance info
				orgRoutes.POST("/:id/promote", governanceHandler.PromoteToAdmin)            // Promote member to admin
				orgRoutes.DELETE("/:id/admins/:user_id", governanceHandler.DemoteFromAdmin) // Demote admin to member
				orgRoutes.POST("/:id/transfer", governanceHandler.RequestAdminTransfer)     // Request admin transfer
				orgRoutes.POST("/:id/archive", governanceHandler.ArchiveOrganization)       // Archive organization
				orgRoutes.POST("/:id/unarchive", governanceHandler.UnarchiveOrganization)   // Restore archived org
			}

			// Admin transfer response (separate endpoint for recipient)
			protected.POST("/admin-transfers/:request_id/respond", governanceHandler.RespondToTransfer)

			// Channel routes (messaging)
			channelRoutes := protected.Group("/channels")
			{
				channelRoutes.GET("", channelHandler.ListChannels)                                // List user's channels
				channelRoutes.POST("", channelHandler.CreateChannel)                              // Create channel
				channelRoutes.POST("/dm", channelHandler.GetOrCreateDM)                           // Get or create DM
				channelRoutes.GET("/:id", channelHandler.GetChannel)                              // Get channel details
				channelRoutes.POST("/:id/members", channelHandler.AddChannelMember)               // Add member
				channelRoutes.DELETE("/:id/members/:user_id", channelHandler.RemoveChannelMember) // Remove member
				channelRoutes.POST("/:id/read", channelHandler.MarkChannelRead)                   // Mark as read

				// Channel governance
				channelRoutes.POST("/:id/archive", governanceHandler.ArchiveChannel)     // Archive channel
				channelRoutes.POST("/:id/unarchive", governanceHandler.UnarchiveChannel) // Restore channel
				channelRoutes.POST("/:id/hide", governanceHandler.HideConversation)      // Hide conversation (DM)
				channelRoutes.POST("/:id/unhide", governanceHandler.UnhideConversation)  // Unhide conversation
			}

			// Message routes (E2E encrypted messages)
			messageRoutes := protected.Group("/messages")
			{
				messageRoutes.POST("", messageHandler.SendMessage)                // Send encrypted message
				messageRoutes.GET("/:channel_id", messageHandler.GetMessages)     // Get message history
				messageRoutes.PUT("/:id", messageHandler.EditMessage)             // Edit message
				messageRoutes.DELETE("/:id", messageHandler.DeleteMessage)        // Delete message
				messageRoutes.POST("/:id/react", messageHandler.AddReaction)      // Add reaction
				messageRoutes.DELETE("/:id/react", messageHandler.RemoveReaction) // Remove reaction
			}

			// Group encryption routes (Sender Keys)
			groupRoutes := protected.Group("/groups")
			{
				groupRoutes.POST("/sender-key", groupHandler.UploadSenderKey)                   // Upload sender key
				groupRoutes.GET("/:channel_id/sender-keys", groupHandler.GetSenderKeys)         // Get all sender keys
				groupRoutes.GET("/:channel_id/sender-keys/:user_id", groupHandler.GetSenderKey) // Get specific sender key
				groupRoutes.DELETE("/:channel_id/sender-key", groupHandler.DeleteSenderKey)     // Delete own sender key
				groupRoutes.POST("/:channel_id/rotate-keys", groupHandler.RotateChannelKeys)    // Force key rotation
				groupRoutes.GET("/:channel_id/key-status", groupHandler.GetChannelKeyStatus)    // Check key status
			}

			// Feed routes
			feedRoutes := protected.Group("/feed")
			{
				feedRoutes.GET("", feedHandler.GetFeed)
				feedRoutes.GET("/v2", feedHandler.GetFeedV2)
				feedRoutes.POST("/posts", feedHandler.CreatePost)
				feedRoutes.GET("/posts/:id", feedHandler.GetPost)
				feedRoutes.DELETE("/posts/:id", feedHandler.DeletePost)
				feedRoutes.POST("/posts/:id/verify", feedHandler.VerifyPost)
				feedRoutes.POST("/posts/:id/flag", feedHandler.FlagPost)
			}

			// News routes (aggregated news from external sources)
			protected.GET("/news", newsHandler.GetNews)

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

			// Device management routes (multi-device support)
			deviceRoutes := protected.Group("/devices")
			{
				deviceRoutes.POST("/link", devicesHandler.SubmitLink)           // Mobile submits encrypted payload
				deviceRoutes.GET("/link/:device_id", devicesHandler.PollLink)   // Desktop polls for payload
				deviceRoutes.POST("/register", devicesHandler.RegisterDevice)   // Register new device
				deviceRoutes.GET("", devicesHandler.ListDevices)                // List user's devices
				deviceRoutes.DELETE("/:id", devicesHandler.RemoveDevice)        // Remove device
			}

			// Push notification routes
			pushRoutes := protected.Group("/push")
			{
				pushRoutes.POST("/token", pushHandler.RegisterToken)
				pushRoutes.DELETE("/token", pushHandler.UnregisterToken)
				pushRoutes.GET("/tokens", pushHandler.GetTokens)
				pushRoutes.GET("/quiet-hours", pushHandler.GetQuietHours)
				pushRoutes.PUT("/quiet-hours", pushHandler.SetQuietHours)
				pushRoutes.DELETE("/quiet-hours", pushHandler.DeleteQuietHours)
			}

			// Admin/bot routes
			adminRoutes := protected.Group("/admin")
			{
				// These handlers check is_admin internally
				botHandler := bot.NewHandler(db, redis)
				adminRoutes.POST("/bot/trigger", botHandler.TriggerRun)
				adminRoutes.POST("/bot/protests/trigger", botHandler.TriggerProtestScrape)
				adminRoutes.GET("/bot/worker-status", botHandler.WorkerStatus)
				adminRoutes.GET("/bot/runs", botHandler.GetRunHistory)
				adminRoutes.GET("/bot/articles", botHandler.GetPostedArticles)
			}

			// WebSocket endpoint for real-time messaging
			protected.GET("/ws", wsHandler.HandleConnection)
		}
	}

	return router, wsHub
}

func healthCheck(db *storage.Postgres, redis *storage.Redis) gin.HandlerFunc {
	return func(c *gin.Context) {
		checks := gin.H{}
		healthy := true

		// Check database
		if err := db.HealthCheck(c.Request.Context()); err != nil {
			checks["database"] = "down"
			healthy = false
		} else {
			checks["database"] = "up"
		}

		// Check Redis
		if err := redis.HealthCheck(c.Request.Context()); err != nil {
			checks["redis"] = "down"
			healthy = false
		} else {
			checks["redis"] = "up"
		}

		// Database pool stats (for monitoring)
		dbStats := db.Stats()
		checks["db_pool"] = gin.H{
			"total_conns": dbStats.TotalConns(),
			"idle_conns":  dbStats.IdleConns(),
			"in_use":      dbStats.TotalConns() - dbStats.IdleConns(),
			"max_conns":   dbStats.MaxConns(),
		}

		// Warn if pool is nearly exhausted (>80% in use)
		poolUsage := float64(dbStats.TotalConns()-dbStats.IdleConns()) / float64(dbStats.MaxConns())
		if poolUsage > 0.8 {
			checks["db_pool_warning"] = "pool usage above 80%"
		}

		if healthy {
			checks["status"] = "healthy"
			c.JSON(http.StatusOK, checks)
		} else {
			checks["status"] = "unhealthy"
			c.JSON(http.StatusServiceUnavailable, checks)
		}
	}
}
