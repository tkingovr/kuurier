package messaging

import (
	"database/sql"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// MessageHandler handles message-related API endpoints
type MessageHandler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewMessageHandler creates a new message handler
func NewMessageHandler(cfg *config.Config, db *storage.Postgres) *MessageHandler {
	return &MessageHandler{cfg: cfg, db: db}
}

// Message represents a chat message
type Message struct {
	ID          string     `json:"id"`
	ChannelID   string     `json:"channel_id"`
	SenderID    string     `json:"sender_id"`
	Ciphertext  []byte     `json:"ciphertext"`
	MessageType string     `json:"message_type"`
	ReplyToID   *string    `json:"reply_to_id,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
	EditedAt    *time.Time `json:"edited_at,omitempty"`
}

// SendMessageRequest is the request body for sending a message
type SendMessageRequest struct {
	ChannelID   string  `json:"channel_id" binding:"required"`
	Ciphertext  []byte  `json:"ciphertext" binding:"required"`
	MessageType string  `json:"message_type"` // text, media, system
	ReplyToID   *string `json:"reply_to_id,omitempty"`
}

// SendMessage sends an encrypted message to a channel
func (h *MessageHandler) SendMessage(c *gin.Context) {
	userID := c.GetString("user_id")

	var req SendMessageRequest
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

	// Default message type
	msgType := req.MessageType
	if msgType == "" {
		msgType = "text"
	}

	// Insert the message
	messageID := uuid.New().String()
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`INSERT INTO messages (id, channel_id, sender_id, ciphertext, message_type, reply_to_id, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, NOW())`,
		messageID, req.ChannelID, userID, req.Ciphertext, msgType, req.ReplyToID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to send message"})
		return
	}

	// Update channel last_activity
	h.db.Pool().Exec(c.Request.Context(),
		`UPDATE channels SET updated_at = NOW() WHERE id = $1`, req.ChannelID)

	// Fetch the created message
	var msg Message
	err = h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT id, channel_id, sender_id, ciphertext, message_type, reply_to_id, created_at, edited_at
		 FROM messages WHERE id = $1`, messageID).Scan(
		&msg.ID, &msg.ChannelID, &msg.SenderID, &msg.Ciphertext,
		&msg.MessageType, &msg.ReplyToID, &msg.CreatedAt, &msg.EditedAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch message"})
		return
	}

	c.JSON(http.StatusCreated, msg)
}

// GetMessages retrieves message history for a channel
func (h *MessageHandler) GetMessages(c *gin.Context) {
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

	// Pagination
	limit := 50
	if l := c.Query("limit"); l != "" {
		if parsed, err := parseIntQuery(l); err == nil && parsed > 0 && parsed <= 100 {
			limit = parsed
		}
	}

	// Optional: fetch messages before a certain timestamp
	beforeTime := time.Now()
	if before := c.Query("before"); before != "" {
		if parsed, err := time.Parse(time.RFC3339, before); err == nil {
			beforeTime = parsed
		}
	}

	// Fetch messages
	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT id, channel_id, sender_id, ciphertext, message_type, reply_to_id, created_at, edited_at
		 FROM messages
		 WHERE channel_id = $1 AND created_at < $2 AND deleted_at IS NULL
		 ORDER BY created_at DESC
		 LIMIT $3`,
		channelID, beforeTime, limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch messages"})
		return
	}
	defer rows.Close()

	var messages []Message
	for rows.Next() {
		var msg Message
		if err := rows.Scan(&msg.ID, &msg.ChannelID, &msg.SenderID, &msg.Ciphertext,
			&msg.MessageType, &msg.ReplyToID, &msg.CreatedAt, &msg.EditedAt); err != nil {
			continue
		}
		messages = append(messages, msg)
	}

	if messages == nil {
		messages = []Message{}
	}

	c.JSON(http.StatusOK, gin.H{"messages": messages})
}

// EditMessage edits an existing message
func (h *MessageHandler) EditMessage(c *gin.Context) {
	userID := c.GetString("user_id")
	messageID := c.Param("id")

	var req struct {
		Ciphertext []byte `json:"ciphertext" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	// Verify user owns this message
	var senderID string
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT sender_id FROM messages WHERE id = $1 AND deleted_at IS NULL`,
		messageID).Scan(&senderID)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "Message not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch message"})
		return
	}

	if senderID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "You can only edit your own messages"})
		return
	}

	// Update the message
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`UPDATE messages SET ciphertext = $1, edited_at = NOW() WHERE id = $2`,
		req.Ciphertext, messageID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to edit message"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Message edited"})
}

// DeleteMessage soft-deletes a message
func (h *MessageHandler) DeleteMessage(c *gin.Context) {
	userID := c.GetString("user_id")
	messageID := c.Param("id")

	// Verify user owns this message (or is channel admin)
	var senderID, channelID string
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT sender_id, channel_id FROM messages WHERE id = $1 AND deleted_at IS NULL`,
		messageID).Scan(&senderID, &channelID)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "Message not found"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch message"})
		return
	}

	// Check if user is sender or channel admin
	if senderID != userID {
		var role string
		h.db.Pool().QueryRow(c.Request.Context(),
			`SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2`,
			channelID, userID).Scan(&role)
		if role != "admin" {
			c.JSON(http.StatusForbidden, gin.H{"error": "You can only delete your own messages"})
			return
		}
	}

	// Soft delete
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`UPDATE messages SET deleted_at = NOW() WHERE id = $1`, messageID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to delete message"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Message deleted"})
}

// AddReaction adds a reaction to a message
func (h *MessageHandler) AddReaction(c *gin.Context) {
	userID := c.GetString("user_id")
	messageID := c.Param("id")

	var req struct {
		EmojiCiphertext []byte `json:"emoji_ciphertext" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	// Verify message exists and user has access
	var channelID string
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT channel_id FROM messages WHERE id = $1 AND deleted_at IS NULL`,
		messageID).Scan(&channelID)
	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "Message not found"})
		return
	}

	// Verify user is member of channel
	var isMember bool
	h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)`,
		channelID, userID).Scan(&isMember)
	if !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "Not a member of this channel"})
		return
	}

	// Upsert reaction
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`INSERT INTO message_reactions (message_id, user_id, emoji_ciphertext, created_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (message_id, user_id) DO UPDATE SET emoji_ciphertext = $3`,
		messageID, userID, req.EmojiCiphertext)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to add reaction"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Reaction added"})
}

// RemoveReaction removes a reaction from a message
func (h *MessageHandler) RemoveReaction(c *gin.Context) {
	userID := c.GetString("user_id")
	messageID := c.Param("id")

	_, err := h.db.Pool().Exec(c.Request.Context(),
		`DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2`,
		messageID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to remove reaction"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Reaction removed"})
}

// Helper function to parse int query params
func parseIntQuery(s string) (int, error) {
	var i int
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("invalid integer")
		}
		i = i*10 + int(c-'0')
	}
	return i, nil
}
