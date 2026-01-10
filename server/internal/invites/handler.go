package invites

import (
	"crypto/rand"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

const (
	// InviteCodeExpiry is how long an invite code is valid
	InviteCodeExpiry = 7 * 24 * time.Hour // 7 days

	// BaseInviteAllowance is how many invites users get at trust 30
	BaseInviteAllowance = 3

	// InvitesPerTrustIncrement is how many additional invites per 20 trust
	InvitesPerTrustIncrement = 1
	TrustIncrementSize       = 20

	// MinTrustToInvite is the minimum trust score to generate invites
	MinTrustToInvite = 30
)

// Handler handles invite-related endpoints
type Handler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewHandler creates a new invites handler
func NewHandler(cfg *config.Config, db *storage.Postgres) *Handler {
	return &Handler{cfg: cfg, db: db}
}

// InviteCode represents an invite code
type InviteCode struct {
	ID        string     `json:"id"`
	Code      string     `json:"code"`
	InviterID string     `json:"inviter_id"`
	InviteeID *string    `json:"invitee_id,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	ExpiresAt time.Time  `json:"expires_at"`
	UsedAt    *time.Time `json:"used_at,omitempty"`
	Status    string     `json:"status"` // "active", "used", "expired"
}

// InvitesResponse is the response for listing invites
type InvitesResponse struct {
	Invites         []InviteCode `json:"invites"`
	TotalAllowance  int          `json:"total_allowance"`
	UsedCount       int          `json:"used_count"`
	ActiveCount     int          `json:"active_count"`
	AvailableToMake int          `json:"available_to_make"`
}

// GenerateInvite creates a new invite code
func (h *Handler) GenerateInvite(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := int(c.GetFloat64("trust_score"))

	// Check trust requirement
	if trustScore < MinTrustToInvite {
		c.JSON(http.StatusForbidden, gin.H{
			"error":    "insufficient trust to generate invites",
			"required": MinTrustToInvite,
			"current":  trustScore,
		})
		return
	}

	ctx := c.Request.Context()

	// Calculate invite allowance
	allowance := calculateInviteAllowance(trustScore)

	// Count existing active and used invites
	var activeCount, usedCount int
	err := h.db.Pool().QueryRow(ctx,
		`SELECT
			COUNT(*) FILTER (WHERE used_at IS NULL AND expires_at > NOW()),
			COUNT(*) FILTER (WHERE used_at IS NOT NULL)
		FROM invite_codes WHERE inviter_id = $1`,
		userID,
	).Scan(&activeCount, &usedCount)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to check invite count"})
		return
	}

	// Check if user can create more invites
	totalUsed := activeCount + usedCount
	if totalUsed >= allowance {
		c.JSON(http.StatusForbidden, gin.H{
			"error":           "invite limit reached",
			"total_allowance": allowance,
			"active":          activeCount,
			"used":            usedCount,
			"message":         "Increase your trust score to get more invites",
		})
		return
	}

	// Generate unique code
	code, err := generateInviteCode()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate code"})
		return
	}

	// Insert invite code
	expiresAt := time.Now().UTC().Add(InviteCodeExpiry)
	var inviteID string
	err = h.db.Pool().QueryRow(ctx,
		`INSERT INTO invite_codes (code, inviter_id, expires_at)
		 VALUES ($1, $2, $3)
		 RETURNING id`,
		code, userID, expiresAt,
	).Scan(&inviteID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create invite"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"id":         inviteID,
		"code":       code,
		"expires_at": expiresAt,
		"message":    "Share this code with someone you trust",
	})
}

// ListInvites returns all invite codes for the current user
func (h *Handler) ListInvites(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := int(c.GetFloat64("trust_score"))

	ctx := c.Request.Context()

	// Get all invites for this user
	rows, err := h.db.Pool().Query(ctx,
		`SELECT id, code, inviter_id, invitee_id, created_at, expires_at, used_at
		 FROM invite_codes
		 WHERE inviter_id = $1
		 ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch invites"})
		return
	}
	defer rows.Close()

	var invites []InviteCode
	var activeCount, usedCount int
	now := time.Now().UTC()

	for rows.Next() {
		var invite InviteCode
		err := rows.Scan(
			&invite.ID,
			&invite.Code,
			&invite.InviterID,
			&invite.InviteeID,
			&invite.CreatedAt,
			&invite.ExpiresAt,
			&invite.UsedAt,
		)
		if err != nil {
			continue
		}

		// Determine status
		if invite.UsedAt != nil {
			invite.Status = "used"
			usedCount++
		} else if invite.ExpiresAt.Before(now) {
			invite.Status = "expired"
		} else {
			invite.Status = "active"
			activeCount++
		}

		invites = append(invites, invite)
	}

	allowance := calculateInviteAllowance(trustScore)
	availableToMake := allowance - activeCount - usedCount
	if availableToMake < 0 {
		availableToMake = 0
	}

	c.JSON(http.StatusOK, InvitesResponse{
		Invites:         invites,
		TotalAllowance:  allowance,
		UsedCount:       usedCount,
		ActiveCount:     activeCount,
		AvailableToMake: availableToMake,
	})
}

// RevokeInvite cancels an unused invite code
func (h *Handler) RevokeInvite(c *gin.Context) {
	userID := c.GetString("user_id")
	code := c.Param("code")

	ctx := c.Request.Context()

	// Delete only if owned by user and unused
	result, err := h.db.Pool().Exec(ctx,
		`DELETE FROM invite_codes
		 WHERE code = $1 AND inviter_id = $2 AND used_at IS NULL`,
		code, userID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to revoke invite"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, gin.H{
			"error": "invite not found or already used",
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "invite revoked",
	})
}

// ValidateInvite checks if an invite code is valid (public endpoint)
func (h *Handler) ValidateInvite(c *gin.Context) {
	code := c.Param("code")

	ctx := c.Request.Context()

	var expiresAt time.Time
	var usedAt *time.Time
	err := h.db.Pool().QueryRow(ctx,
		`SELECT expires_at, used_at FROM invite_codes WHERE code = $1`,
		code,
	).Scan(&expiresAt, &usedAt)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{
			"valid":   false,
			"error":   "invalid invite code",
			"message": "This invite code does not exist",
		})
		return
	}

	if usedAt != nil {
		c.JSON(http.StatusGone, gin.H{
			"valid":   false,
			"error":   "invite already used",
			"message": "This invite code has already been used",
		})
		return
	}

	if expiresAt.Before(time.Now().UTC()) {
		c.JSON(http.StatusGone, gin.H{
			"valid":   false,
			"error":   "invite expired",
			"message": "This invite code has expired",
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"valid":      true,
		"expires_at": expiresAt,
		"message":    "Invite code is valid",
	})
}

// GetInviteStats returns invite statistics (for admin/debugging)
func (h *Handler) GetInviteStats(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := int(c.GetFloat64("trust_score"))

	ctx := c.Request.Context()

	var activeCount, usedCount, expiredCount int
	err := h.db.Pool().QueryRow(ctx,
		`SELECT
			COUNT(*) FILTER (WHERE used_at IS NULL AND expires_at > NOW()),
			COUNT(*) FILTER (WHERE used_at IS NOT NULL),
			COUNT(*) FILTER (WHERE used_at IS NULL AND expires_at <= NOW())
		FROM invite_codes WHERE inviter_id = $1`,
		userID,
	).Scan(&activeCount, &usedCount, &expiredCount)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to get stats"})
		return
	}

	allowance := calculateInviteAllowance(trustScore)

	c.JSON(http.StatusOK, gin.H{
		"trust_score":       trustScore,
		"total_allowance":   allowance,
		"active_invites":    activeCount,
		"used_invites":      usedCount,
		"expired_invites":   expiredCount,
		"available_to_make": max(0, allowance-activeCount-usedCount),
	})
}

// calculateInviteAllowance returns how many total invites a user can have
func calculateInviteAllowance(trustScore int) int {
	if trustScore < MinTrustToInvite {
		return 0
	}

	// Base allowance at trust 30
	allowance := BaseInviteAllowance

	// Additional invites for trust above 30
	extraTrust := trustScore - MinTrustToInvite
	additionalInvites := (extraTrust / TrustIncrementSize) * InvitesPerTrustIncrement

	return allowance + additionalInvites
}

// generateInviteCode creates a unique invite code
func generateInviteCode() (string, error) {
	const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // Removed ambiguous chars: 0,O,1,I
	const codeLength = 6

	bytes := make([]byte, codeLength)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}

	for i := range bytes {
		bytes[i] = charset[bytes[i]%byte(len(charset))]
	}

	return fmt.Sprintf("KUU-%s", string(bytes)), nil
}

// max returns the larger of two ints
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
