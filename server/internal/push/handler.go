package push

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles push notification HTTP endpoints
type Handler struct {
	cfg     *config.Config
	db      *storage.Postgres
	service *Service
}

// NewHandler creates a new push notification handler
func NewHandler(cfg *config.Config, db *storage.Postgres, service *Service) *Handler {
	return &Handler{
		cfg:     cfg,
		db:      db,
		service: service,
	}
}

// RegisterTokenRequest is the request body for token registration
type RegisterTokenRequest struct {
	Token    string `json:"token" binding:"required"`
	Platform string `json:"platform" binding:"required,oneof=ios android"`
}

// RegisterToken registers a device token for push notifications
// POST /push/token
func (h *Handler) RegisterToken(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	var req RegisterTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Validate token length (APNs tokens are 64 hex chars)
	if len(req.Token) < 32 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid token format"})
		return
	}

	ctx := c.Request.Context()

	if err := h.service.RegisterToken(ctx, userID, req.Token, req.Platform); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to register token"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "token registered"})
}

// UnregisterTokenRequest is the request body for token removal
type UnregisterTokenRequest struct {
	Token string `json:"token" binding:"required"`
}

// UnregisterToken removes a device token
// DELETE /push/token
func (h *Handler) UnregisterToken(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	var req UnregisterTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ctx := c.Request.Context()

	if err := h.service.UnregisterToken(ctx, userID, req.Token); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to unregister token"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "token unregistered"})
}

// GetTokens returns all registered tokens for the current user (for debugging)
// GET /push/tokens
func (h *Handler) GetTokens(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx,
		"SELECT token, platform, created_at FROM push_tokens WHERE user_id = $1",
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch tokens"})
		return
	}
	defer rows.Close()

	type TokenInfo struct {
		Token     string `json:"token"`
		Platform  string `json:"platform"`
		CreatedAt string `json:"created_at"`
	}

	var tokens []TokenInfo
	for rows.Next() {
		var t TokenInfo
		var createdAt interface{}
		if err := rows.Scan(&t.Token, &t.Platform, &createdAt); err != nil {
			continue
		}
		// Mask token for security
		if len(t.Token) > 20 {
			t.Token = t.Token[:10] + "..." + t.Token[len(t.Token)-10:]
		}
		tokens = append(tokens, t)
	}

	c.JSON(http.StatusOK, gin.H{"tokens": tokens})
}
