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
	"github.com/kuurier/server/internal/middleware"
	"github.com/kuurier/server/internal/storage"
)

// NewRouter creates and configures the API router
func NewRouter(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *gin.Engine {
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

	// Initialize handlers
	authHandler := auth.NewHandler(cfg, db)
	invitesHandler := invites.NewHandler(cfg, db)
	feedHandler := feed.NewHandler(cfg, db, redis)
	geoHandler := geo.NewHandler(cfg, db, redis)
	eventsHandler := events.NewHandler(cfg, db, redis)
	alertsHandler := alerts.NewHandler(cfg, db, redis)

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
				eventRoutes.GET("/:id", eventsHandler.GetEvent)
				eventRoutes.PUT("/:id", eventsHandler.UpdateEvent)
				eventRoutes.DELETE("/:id", eventsHandler.DeleteEvent)
				eventRoutes.POST("/:id/rsvp", eventsHandler.RSVP)
				eventRoutes.DELETE("/:id/rsvp", eventsHandler.CancelRSVP)
				eventRoutes.GET("/nearby", eventsHandler.GetNearbyEvents)
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
		}
	}

	return router
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
