package messaging

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// GovernanceHandler handles organization governance endpoints
type GovernanceHandler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewGovernanceHandler creates a new governance handler
func NewGovernanceHandler(cfg *config.Config, db *storage.Postgres) *GovernanceHandler {
	return &GovernanceHandler{cfg: cfg, db: db}
}

// ============================================================================
// ADMIN MANAGEMENT
// ============================================================================

// PromoteToAdminRequest is the request for promoting a member to admin
type PromoteToAdminRequest struct {
	UserID string `json:"user_id" binding:"required"`
}

// PromoteToAdmin promotes a member to admin role
func (h *GovernanceHandler) PromoteToAdmin(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	var req PromoteToAdminRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Check if requesting user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can promote members"})
		return
	}

	// Check if target user is a member
	var targetRole string
	err = h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, req.UserID).Scan(&targetRole)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user is not a member of this organization"})
		return
	}

	if targetRole == "admin" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "user is already an admin"})
		return
	}

	// Promote to admin
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE organization_members SET role = 'admin' WHERE org_id = $1 AND user_id = $2
	`, orgID, req.UserID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to promote user"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "user promoted to admin"})
}

// DemoteFromAdmin demotes an admin to member role
func (h *GovernanceHandler) DemoteFromAdmin(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	targetUserID := c.Param("user_id")
	ctx := c.Request.Context()

	// Check if requesting user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can demote members"})
		return
	}

	// Count admins
	var adminCount int
	h.db.Pool().QueryRow(ctx, `
		SELECT COUNT(*) FROM organization_members WHERE org_id = $1 AND role = 'admin'
	`, orgID).Scan(&adminCount)

	// Get org min_admins requirement
	var minAdmins int
	h.db.Pool().QueryRow(ctx, `SELECT COALESCE(min_admins, 1) FROM organizations WHERE id = $1`, orgID).Scan(&minAdmins)

	if adminCount <= minAdmins {
		c.JSON(http.StatusForbidden, gin.H{
			"error":      "cannot demote: organization requires at least " + string(rune('0'+minAdmins)) + " admin(s)",
			"min_admins": minAdmins,
		})
		return
	}

	// Demote to member
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE organization_members SET role = 'member' WHERE org_id = $1 AND user_id = $2 AND role = 'admin'
	`, orgID, targetUserID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to demote user"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "user demoted to member"})
}

// TransferAdminRequest is the request for transferring admin role
type TransferAdminRequest struct {
	ToUserID string `json:"to_user_id" binding:"required"`
}

// RequestAdminTransfer creates a request to transfer admin role to another user
func (h *GovernanceHandler) RequestAdminTransfer(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	var req TransferAdminRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Check if requesting user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can transfer admin role"})
		return
	}

	// Check if target user is a member
	var targetRole string
	err = h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, req.ToUserID).Scan(&targetRole)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user is not a member of this organization"})
		return
	}

	// Create transfer request
	expiresAt := time.Now().Add(7 * 24 * time.Hour)
	var requestID string
	err = h.db.Pool().QueryRow(ctx, `
		INSERT INTO admin_transfer_requests (org_id, from_user_id, to_user_id, expires_at)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (org_id, from_user_id, to_user_id, status)
		DO UPDATE SET created_at = NOW(), expires_at = $4
		RETURNING id
	`, orgID, userID, req.ToUserID, expiresAt).Scan(&requestID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create transfer request"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"id":         requestID,
		"message":    "admin transfer request created",
		"expires_at": expiresAt,
	})
}

// RespondToTransfer handles accepting/rejecting an admin transfer request
func (h *GovernanceHandler) RespondToTransfer(c *gin.Context) {
	userID := c.GetString("user_id")
	requestID := c.Param("request_id")
	ctx := c.Request.Context()

	var req struct {
		Accept bool `json:"accept"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Get the transfer request
	var orgID, fromUserID, toUserID, status string
	var expiresAt time.Time
	err := h.db.Pool().QueryRow(ctx, `
		SELECT org_id, from_user_id, to_user_id, status, expires_at
		FROM admin_transfer_requests WHERE id = $1
	`, requestID).Scan(&orgID, &fromUserID, &toUserID, &status, &expiresAt)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "transfer request not found"})
		return
	}

	// Check if this user is the recipient
	if toUserID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "you are not the recipient of this transfer request"})
		return
	}

	// Check status
	if status != "pending" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "this request has already been " + status})
		return
	}

	// Check expiry
	if time.Now().After(expiresAt) {
		h.db.Pool().Exec(ctx, `UPDATE admin_transfer_requests SET status = 'expired' WHERE id = $1`, requestID)
		c.JSON(http.StatusBadRequest, gin.H{"error": "this request has expired"})
		return
	}

	if req.Accept {
		// Start transaction
		tx, err := h.db.Pool().Begin(ctx)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "database error"})
			return
		}
		defer tx.Rollback(ctx)

		// Promote recipient to admin
		_, err = tx.Exec(ctx, `
			UPDATE organization_members SET role = 'admin' WHERE org_id = $1 AND user_id = $2
		`, orgID, toUserID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to promote user"})
			return
		}

		// Mark request as accepted
		_, err = tx.Exec(ctx, `
			UPDATE admin_transfer_requests SET status = 'accepted', responded_at = NOW() WHERE id = $1
		`, requestID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update request"})
			return
		}

		if err := tx.Commit(ctx); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to commit"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"message": "admin transfer accepted, you are now an admin"})
	} else {
		// Reject the request
		_, err = h.db.Pool().Exec(ctx, `
			UPDATE admin_transfer_requests SET status = 'rejected', responded_at = NOW() WHERE id = $1
		`, requestID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to reject request"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"message": "admin transfer rejected"})
	}
}

// ============================================================================
// ORGANIZATION ARCHIVE
// ============================================================================

// ArchiveOrganization archives an organization (soft delete)
func (h *GovernanceHandler) ArchiveOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can archive organizations"})
		return
	}

	// Archive the organization
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE organizations SET archived_at = NOW(), archived_by = $2 WHERE id = $1 AND archived_at IS NULL
	`, orgID, userID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to archive organization"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "organization archived"})
}

// UnarchiveOrganization restores an archived organization
func (h *GovernanceHandler) UnarchiveOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can unarchive organizations"})
		return
	}

	// Unarchive
	result, err := h.db.Pool().Exec(ctx, `
		UPDATE organizations SET archived_at = NULL, archived_by = NULL WHERE id = $1 AND archived_at IS NOT NULL
	`, orgID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to unarchive organization"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "organization is not archived"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "organization restored"})
}

// SafeDeleteOrganization deletes an organization with safeguards
func (h *GovernanceHandler) SafeDeleteOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can delete organizations"})
		return
	}

	// Check deletion criteria using the helper function
	var canDelete bool
	err = h.db.Pool().QueryRow(ctx, `SELECT org_can_hard_delete($1, $2)`, orgID, userID).Scan(&canDelete)

	if err != nil || !canDelete {
		// Get more details for the error message
		var memberCount int
		var hasMessages bool
		h.db.Pool().QueryRow(ctx, `
			SELECT COUNT(*) FROM organization_members WHERE org_id = $1 AND user_id != $2
		`, orgID, userID).Scan(&memberCount)

		h.db.Pool().QueryRow(ctx, `
			SELECT EXISTS(SELECT 1 FROM messages m JOIN channels c ON m.channel_id = c.id WHERE c.org_id = $1)
		`, orgID).Scan(&hasMessages)

		reasons := []string{}
		if memberCount > 0 {
			reasons = append(reasons, "organization has other members")
		}
		if hasMessages {
			reasons = append(reasons, "channels contain messages")
		}

		c.JSON(http.StatusForbidden, gin.H{
			"error":        "cannot delete organization",
			"reasons":      reasons,
			"suggestion":   "Archive the organization instead, or remove all members first",
			"member_count": memberCount,
			"has_messages": hasMessages,
		})
		return
	}

	// Safe to delete
	_, err = h.db.Pool().Exec(ctx, `DELETE FROM organizations WHERE id = $1`, orgID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete organization"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "organization permanently deleted"})
}

// ============================================================================
// CONVERSATION VISIBILITY (DM Hide/Archive)
// ============================================================================

// HideConversation hides a conversation from the user's view
func (h *GovernanceHandler) HideConversation(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is member of the channel
	var exists bool
	err := h.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)
	`, channelID, userID).Scan(&exists)

	if err != nil || !exists {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this conversation"})
		return
	}

	// Insert or update visibility
	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO conversation_visibility (channel_id, user_id, hidden_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (channel_id, user_id)
		DO UPDATE SET hidden_at = NOW()
	`, channelID, userID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to hide conversation"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "conversation hidden"})
}

// UnhideConversation makes a hidden conversation visible again
func (h *GovernanceHandler) UnhideConversation(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	_, err := h.db.Pool().Exec(ctx, `
		UPDATE conversation_visibility SET hidden_at = NULL
		WHERE channel_id = $1 AND user_id = $2
	`, channelID, userID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to unhide conversation"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "conversation restored"})
}

// ============================================================================
// CHANNEL ARCHIVE
// ============================================================================

// ArchiveChannel archives a channel (soft delete)
func (h *GovernanceHandler) ArchiveChannel(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is channel admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2
	`, channelID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only channel admins can archive channels"})
		return
	}

	// Archive the channel
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE channels SET archived_at = NOW(), archived_by = $2 WHERE id = $1 AND archived_at IS NULL
	`, channelID, userID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to archive channel"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "channel archived"})
}

// UnarchiveChannel restores an archived channel
func (h *GovernanceHandler) UnarchiveChannel(c *gin.Context) {
	userID := c.GetString("user_id")
	channelID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is channel admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM channel_members WHERE channel_id = $1 AND user_id = $2
	`, channelID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only channel admins can unarchive channels"})
		return
	}

	// Unarchive
	result, err := h.db.Pool().Exec(ctx, `
		UPDATE channels SET archived_at = NULL, archived_by = NULL WHERE id = $1 AND archived_at IS NOT NULL
	`, channelID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to unarchive channel"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "channel is not archived"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "channel restored"})
}

// GetOrgGovernanceInfo returns governance info for an organization
func (h *GovernanceHandler) GetOrgGovernanceInfo(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is member
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this organization"})
		return
	}

	// Get org info
	var name string
	var minAdmins int
	var isArchived bool
	h.db.Pool().QueryRow(ctx, `
		SELECT name, COALESCE(min_admins, 1), archived_at IS NOT NULL
		FROM organizations WHERE id = $1
	`, orgID).Scan(&name, &minAdmins, &isArchived)

	// Count admins and members
	var adminCount, memberCount int
	h.db.Pool().QueryRow(ctx, `
		SELECT
			COUNT(*) FILTER (WHERE role = 'admin'),
			COUNT(*)
		FROM organization_members WHERE org_id = $1
	`, orgID).Scan(&adminCount, &memberCount)

	// Get pending transfer requests for this user
	var pendingTransfers []gin.H
	rows, _ := h.db.Pool().Query(ctx, `
		SELECT id, from_user_id, expires_at
		FROM admin_transfer_requests
		WHERE org_id = $1 AND to_user_id = $2 AND status = 'pending' AND expires_at > NOW()
	`, orgID, userID)
	if rows != nil {
		defer rows.Close()
		for rows.Next() {
			var id, fromUserID string
			var expiresAt time.Time
			rows.Scan(&id, &fromUserID, &expiresAt)
			pendingTransfers = append(pendingTransfers, gin.H{
				"id":           id,
				"from_user_id": fromUserID,
				"expires_at":   expiresAt,
			})
		}
	}

	// Check if user can leave
	var canLeave bool
	h.db.Pool().QueryRow(ctx, `SELECT user_can_leave_org($1, $2)`, orgID, userID).Scan(&canLeave)

	// Check if org can be deleted
	var canDelete bool
	if role == "admin" {
		h.db.Pool().QueryRow(ctx, `SELECT org_can_hard_delete($1, $2)`, orgID, userID).Scan(&canDelete)
	}

	c.JSON(http.StatusOK, gin.H{
		"org_id":            orgID,
		"name":              name,
		"user_role":         role,
		"admin_count":       adminCount,
		"member_count":      memberCount,
		"min_admins":        minAdmins,
		"is_archived":       isArchived,
		"can_leave":         canLeave,
		"can_delete":        canDelete,
		"pending_transfers": pendingTransfers,
	})
}
