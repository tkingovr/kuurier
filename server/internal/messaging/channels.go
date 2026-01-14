package messaging

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// ChannelHandler handles channel-related endpoints
type ChannelHandler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewChannelHandler creates a new channel handler
func NewChannelHandler(cfg *config.Config, db *storage.Postgres) *ChannelHandler {
	return &ChannelHandler{cfg: cfg, db: db}
}

// Channel represents a chat channel
type Channel struct {
	ID           string    `json:"id"`
	OrgID        *string   `json:"org_id,omitempty"`
	Name         *string   `json:"name,omitempty"`
	Description  *string   `json:"description,omitempty"`
	Type         string    `json:"type"` // public, private, dm, event
	EventID      *string   `json:"event_id,omitempty"`
	CreatedBy    string    `json:"created_by"`
	CreatedAt    time.Time `json:"created_at"`
	MemberCount  int       `json:"member_count,omitempty"`
	UnreadCount  int       `json:"unread_count,omitempty"`
	LastMessage  *string   `json:"last_message,omitempty"`      // Preview (encrypted)
	LastActivity *time.Time `json:"last_activity,omitempty"`
	// For DMs, include the other user's info
	OtherUserID  *string   `json:"other_user_id,omitempty"`
}

// CreateChannelRequest is the request for creating a channel
type CreateChannelRequest struct {
	OrgID       string  `json:"org_id" binding:"required"`
	Name        string  `json:"name" binding:"required,min=1,max=100"`
	Description *string `json:"description"`
	Type        string  `json:"type" binding:"required,oneof=public private"`
	EventID     *string `json:"event_id"`
}

// CreateChannel creates a new channel in an organization
func (h *ChannelHandler) CreateChannel(c *gin.Context) {
	userID := c.GetString("user_id")

	var req CreateChannelRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	ctx := c.Request.Context()

	// Check if user is member of the org (and has permission to create channels)
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, req.OrgID, userID).Scan(&role)

	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this organization"})
		return
	}

	// Only admins and moderators can create private channels
	if req.Type == "private" && role != "admin" && role != "moderator" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins and moderators can create private channels"})
		return
	}

	channelID := uuid.New().String()
	now := time.Now().UTC()

	// Start transaction
	tx, err := h.db.Pool().Begin(ctx)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "database error"})
		return
	}
	defer tx.Rollback(ctx)

	// Create channel
	_, err = tx.Exec(ctx, `
		INSERT INTO channels (id, org_id, name, description, type, event_id, created_by, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
	`, channelID, req.OrgID, req.Name, req.Description, req.Type, req.EventID, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create channel"})
		return
	}

	// Add creator to channel
	_, err = tx.Exec(ctx, `
		INSERT INTO channel_members (channel_id, user_id, role, joined_at)
		VALUES ($1, $2, 'admin', $3)
	`, channelID, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to add creator to channel"})
		return
	}

	// For public channels, add all org members
	if req.Type == "public" {
		_, err = tx.Exec(ctx, `
			INSERT INTO channel_members (channel_id, user_id, role, joined_at)
			SELECT $1, om.user_id, 'member', $2
			FROM organization_members om
			WHERE om.org_id = $3 AND om.user_id != $4
			ON CONFLICT (channel_id, user_id) DO NOTHING
		`, channelID, now, req.OrgID, userID)
		if err != nil {
			// Non-critical, continue
		}
	}

	if err := tx.Commit(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to commit transaction"})
		return
	}

	c.JSON(http.StatusCreated, Channel{
		ID:          channelID,
		OrgID:       &req.OrgID,
		Name:        &req.Name,
		Description: req.Description,
		Type:        req.Type,
		EventID:     req.EventID,
		CreatedBy:   userID,
		CreatedAt:   now,
		MemberCount: 1,
	})
}

// ListChannels returns channels the user is a member of
func (h *ChannelHandler) ListChannels(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Query("org_id") // Optional filter by org
	ctx := c.Request.Context()

	query := `
		SELECT c.id, c.org_id, c.name, c.description, c.type, c.event_id, c.created_by, c.created_at,
		       (SELECT COUNT(*) FROM channel_members WHERE channel_id = c.id) as member_count,
		       get_unread_count(c.id, $1) as unread_count,
		       (SELECT created_at FROM messages WHERE channel_id = c.id ORDER BY created_at DESC LIMIT 1) as last_activity
		FROM channels c
		JOIN channel_members cm ON c.id = cm.channel_id
		WHERE cm.user_id = $1
	`
	args := []interface{}{userID}

	if orgID != "" {
		query += " AND c.org_id = $2"
		args = append(args, orgID)
	}

	query += " ORDER BY last_activity DESC NULLS LAST, c.created_at DESC"

	rows, err := h.db.Pool().Query(ctx, query, args...)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch channels"})
		return
	}
	defer rows.Close()

	var channels []Channel
	for rows.Next() {
		var ch Channel
		if err := rows.Scan(&ch.ID, &ch.OrgID, &ch.Name, &ch.Description, &ch.Type,
			&ch.EventID, &ch.CreatedBy, &ch.CreatedAt, &ch.MemberCount, &ch.UnreadCount, &ch.LastActivity); err != nil {
			continue
		}

		// For DMs, get the other user's ID
		if ch.Type == "dm" {
			var otherUserID string
			h.db.Pool().QueryRow(ctx, `
				SELECT user_id FROM channel_members WHERE channel_id = $1 AND user_id != $2 LIMIT 1
			`, ch.ID, userID).Scan(&otherUserID)
			if otherUserID != "" {
				ch.OtherUserID = &otherUserID
			}
		}

		channels = append(channels, ch)
	}

	c.JSON(http.StatusOK, gin.H{"channels": channels})
}

// GetChannel returns details of a specific channel
func (h *ChannelHandler) GetChannel(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	// Check membership
	var exists bool
	err := h.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)
	`, channelID, userID).Scan(&exists)

	if err != nil || !exists {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this channel"})
		return
	}

	var ch Channel
	err = h.db.Pool().QueryRow(ctx, `
		SELECT c.id, c.org_id, c.name, c.description, c.type, c.event_id, c.created_by, c.created_at,
		       (SELECT COUNT(*) FROM channel_members WHERE channel_id = c.id) as member_count,
		       get_unread_count(c.id, $2) as unread_count
		FROM channels c
		WHERE c.id = $1
	`, channelID, userID).Scan(&ch.ID, &ch.OrgID, &ch.Name, &ch.Description, &ch.Type,
		&ch.EventID, &ch.CreatedBy, &ch.CreatedAt, &ch.MemberCount, &ch.UnreadCount)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "channel not found"})
		return
	}

	c.JSON(http.StatusOK, ch)
}

// GetOrCreateDMRequest is the request for getting/creating a DM channel
type GetOrCreateDMRequest struct {
	UserID string `json:"user_id" binding:"required"`
}

// GetOrCreateDM gets or creates a DM channel with another user
func (h *ChannelHandler) GetOrCreateDM(c *gin.Context) {
	userID := c.GetString("user_id")

	var req GetOrCreateDMRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	if req.UserID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot create DM with yourself"})
		return
	}

	ctx := c.Request.Context()

	// Check if target user exists
	var exists bool
	err := h.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)
	`, req.UserID).Scan(&exists)

	if err != nil || !exists {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	// Get or create DM channel using the helper function
	var channelID string
	err = h.db.Pool().QueryRow(ctx, `SELECT get_or_create_dm_channel($1, $2)`, userID, req.UserID).Scan(&channelID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create DM channel"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"channel_id":    channelID,
		"other_user_id": req.UserID,
	})
}

// AddChannelMember adds a member to a private channel (admin only)
func (h *ChannelHandler) AddChannelMember(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")

	type AddMemberRequest struct {
		UserID string `json:"user_id" binding:"required"`
	}

	var req AddMemberRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	ctx := c.Request.Context()

	// Check if user is channel admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2
	`, channelID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only channel admins can add members"})
		return
	}

	// Add member
	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO channel_members (channel_id, user_id, role, joined_at)
		VALUES ($1, $2, 'member', NOW())
		ON CONFLICT (channel_id, user_id) DO NOTHING
	`, channelID, req.UserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to add member"})
		return
	}

	// Trigger key rotation by deleting all sender keys
	// This forces all members to regenerate their keys
	_, _ = h.db.Pool().Exec(ctx, `DELETE FROM channel_sender_keys WHERE channel_id = $1`, channelID)

	c.JSON(http.StatusOK, gin.H{"message": "member added", "keys_rotated": true})
}

// RemoveChannelMember removes a member from a channel
func (h *ChannelHandler) RemoveChannelMember(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	targetUserID := c.Param("user_id")
	ctx := c.Request.Context()

	// Check if user is channel admin OR removing themselves
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2
	`, channelID, userID).Scan(&role)

	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this channel"})
		return
	}

	if userID != targetUserID && role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only channel admins can remove other members"})
		return
	}

	// Remove member
	_, err = h.db.Pool().Exec(ctx, `
		DELETE FROM channel_members WHERE channel_id = $1 AND user_id = $2
	`, channelID, targetUserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to remove member"})
		return
	}

	// Delete removed member's sender key and trigger rotation for remaining members
	_, _ = h.db.Pool().Exec(ctx, `DELETE FROM channel_sender_keys WHERE channel_id = $1`, channelID)

	c.JSON(http.StatusOK, gin.H{"message": "member removed", "keys_rotated": true})
}

// MarkChannelRead marks all messages in a channel as read
func (h *ChannelHandler) MarkChannelRead(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	// Use the helper function
	_, err := h.db.Pool().Exec(ctx, `SELECT mark_channel_read($1, $2)`, channelID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to mark channel as read"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "marked as read"})
}
