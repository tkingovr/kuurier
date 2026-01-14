package messaging

import (
	"database/sql"
	"encoding/base64"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// GroupHandler handles group encryption-related API endpoints
type GroupHandler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewGroupHandler creates a new group handler
func NewGroupHandler(cfg *config.Config, db *storage.Postgres) *GroupHandler {
	return &GroupHandler{cfg: cfg, db: db}
}

// SenderKey represents a user's sender key for a channel
type SenderKey struct {
	ChannelID      string    `json:"channel_id"`
	UserID         string    `json:"user_id"`
	DistributionID string    `json:"distribution_id"`
	SenderKey      string    `json:"sender_key"` // Base64 encoded
	Iteration      int       `json:"iteration"`
	CreatedAt      time.Time `json:"created_at"`
}

// UploadSenderKeyRequest is the request for uploading a sender key
type UploadSenderKeyRequest struct {
	ChannelID      string `json:"channel_id" binding:"required"`
	DistributionID string `json:"distribution_id" binding:"required"`
	SenderKey      string `json:"sender_key" binding:"required"` // Base64 encoded
}

// UploadSenderKey uploads or updates a sender key for a channel
func (h *GroupHandler) UploadSenderKey(c *gin.Context) {
	userID := c.GetString("user_id")

	var req UploadSenderKeyRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	// Verify user is a member of the channel
	var isMember bool
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)`,
		req.ChannelID, userID).Scan(&isMember)
	if err != nil || !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}

	// Decode the sender key
	senderKeyBytes, err := base64.StdEncoding.DecodeString(req.SenderKey)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid sender key encoding"})
		return
	}

	// Parse distribution ID
	distID, err := uuid.Parse(req.DistributionID)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid distribution ID"})
		return
	}

	// Upsert sender key
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`INSERT INTO channel_sender_keys (channel_id, user_id, distribution_id, sender_key, iteration, created_at)
		 VALUES ($1, $2, $3, $4, 0, NOW())
		 ON CONFLICT (channel_id, user_id)
		 DO UPDATE SET distribution_id = $3, sender_key = $4, iteration = channel_sender_keys.iteration + 1, created_at = NOW()`,
		req.ChannelID, userID, distID, senderKeyBytes)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to store sender key"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Sender key uploaded"})
}

// GetSenderKeys retrieves all sender keys for a channel
func (h *GroupHandler) GetSenderKeys(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("channel_id")

	// Verify user is a member of the channel
	var isMember bool
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)`,
		channelID, userID).Scan(&isMember)
	if err != nil || !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}

	// Fetch all sender keys for the channel
	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT channel_id, user_id, distribution_id, sender_key, iteration, created_at
		 FROM channel_sender_keys
		 WHERE channel_id = $1`,
		channelID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch sender keys"})
		return
	}
	defer rows.Close()

	var keys []SenderKey
	for rows.Next() {
		var key SenderKey
		var senderKeyBytes []byte
		var distID uuid.UUID
		if err := rows.Scan(&key.ChannelID, &key.UserID, &distID, &senderKeyBytes, &key.Iteration, &key.CreatedAt); err != nil {
			continue
		}
		key.DistributionID = distID.String()
		key.SenderKey = base64.StdEncoding.EncodeToString(senderKeyBytes)
		keys = append(keys, key)
	}

	if keys == nil {
		keys = []SenderKey{}
	}

	c.JSON(http.StatusOK, gin.H{"sender_keys": keys})
}

// GetSenderKey retrieves a specific user's sender key for a channel
func (h *GroupHandler) GetSenderKey(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("channel_id")
	targetUserID := c.Param("user_id")

	// Verify requester is a member of the channel
	var isMember bool
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)`,
		channelID, userID).Scan(&isMember)
	if err != nil || !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}

	// Fetch the sender key
	var key SenderKey
	var senderKeyBytes []byte
	var distID uuid.UUID
	err = h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT channel_id, user_id, distribution_id, sender_key, iteration, created_at
		 FROM channel_sender_keys
		 WHERE channel_id = $1 AND user_id = $2`,
		channelID, targetUserID).Scan(&key.ChannelID, &key.UserID, &distID, &senderKeyBytes, &key.Iteration, &key.CreatedAt)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "Sender key not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch sender key"})
		return
	}

	key.DistributionID = distID.String()
	key.SenderKey = base64.StdEncoding.EncodeToString(senderKeyBytes)

	c.JSON(http.StatusOK, key)
}

// DeleteSenderKey deletes a user's sender key (for key rotation)
func (h *GroupHandler) DeleteSenderKey(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("channel_id")

	// Delete the user's sender key
	_, err := h.db.Pool().Exec(c.Request.Context(),
		`DELETE FROM channel_sender_keys WHERE channel_id = $1 AND user_id = $2`,
		channelID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to delete sender key"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Sender key deleted"})
}

// RotateChannelKeys marks all sender keys in a channel as needing rotation
// This is called when a member joins or leaves
func (h *GroupHandler) RotateChannelKeys(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("channel_id")

	// Verify user is an admin of the channel
	var role string
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2`,
		channelID, userID).Scan(&role)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to check membership"})
		return
	}

	// For now, any member can trigger rotation (could restrict to admins)
	// Delete all sender keys to force regeneration
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`DELETE FROM channel_sender_keys WHERE channel_id = $1`,
		channelID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to rotate keys"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Channel keys rotated"})
}

// GetChannelKeyStatus returns which members have uploaded sender keys
func (h *GroupHandler) GetChannelKeyStatus(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("channel_id")

	// Verify user is a member of the channel
	var isMember bool
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)`,
		channelID, userID).Scan(&isMember)
	if err != nil || !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}

	// Get all members and their key status
	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT cm.user_id,
		        CASE WHEN csk.user_id IS NOT NULL THEN true ELSE false END as has_key,
		        csk.iteration
		 FROM channel_members cm
		 LEFT JOIN channel_sender_keys csk ON cm.channel_id = csk.channel_id AND cm.user_id = csk.user_id
		 WHERE cm.channel_id = $1`,
		channelID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch key status"})
		return
	}
	defer rows.Close()

	type MemberKeyStatus struct {
		UserID    string `json:"user_id"`
		HasKey    bool   `json:"has_key"`
		Iteration *int   `json:"iteration,omitempty"`
	}

	var statuses []MemberKeyStatus
	for rows.Next() {
		var status MemberKeyStatus
		var iteration sql.NullInt32
		if err := rows.Scan(&status.UserID, &status.HasKey, &iteration); err != nil {
			continue
		}
		if iteration.Valid {
			i := int(iteration.Int32)
			status.Iteration = &i
		}
		statuses = append(statuses, status)
	}

	if statuses == nil {
		statuses = []MemberKeyStatus{}
	}

	c.JSON(http.StatusOK, gin.H{"members": statuses})
}
