package auth

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles authentication endpoints
type Handler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewHandler creates a new auth handler
func NewHandler(cfg *config.Config, db *storage.Postgres) *Handler {
	return &Handler{cfg: cfg, db: db}
}

// RegisterRequest is the request body for registration
type RegisterRequest struct {
	PublicKey  string `json:"public_key" binding:"required"` // Base64 encoded Ed25519 public key
	InviteCode string `json:"invite_code"`                   // Invite code (required for new users only)
}

// RegisterResponse is the response for successful registration
type RegisterResponse struct {
	UserID     string `json:"user_id"`
	Challenge  string `json:"challenge"`   // Sign this to complete registration
	TrustScore int    `json:"trust_score"` // Initial trust score
}

// InitialTrustScore is the trust given to users who join via invite
const InitialTrustScore = 15

// Register creates a new anonymous user account (requires invite code)
func (h *Handler) Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Decode and validate public key
	pubKeyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
	if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key"})
		return
	}

	ctx := c.Request.Context()

	// Check if public key already exists (login flow)
	var existingID string
	err = h.db.Pool().QueryRow(ctx,
		"SELECT id FROM users WHERE public_key = $1",
		pubKeyBytes,
	).Scan(&existingID)

	if err == nil {
		// User already exists, return challenge for login (ignore invite code)
		challenge, err := h.createChallenge(ctx, existingID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create challenge"})
			return
		}
		// Get existing trust score
		var trustScore int
		h.db.Pool().QueryRow(ctx, "SELECT trust_score FROM users WHERE id = $1", existingID).Scan(&trustScore)

		c.JSON(http.StatusOK, RegisterResponse{
			UserID:     existingID,
			Challenge:  challenge,
			TrustScore: trustScore,
		})
		return
	}

	// Validate invite code
	var inviterID string
	var expiresAt time.Time
	var usedAt *time.Time
	err = h.db.Pool().QueryRow(ctx,
		`SELECT inviter_id, expires_at, used_at FROM invite_codes WHERE code = $1`,
		req.InviteCode,
	).Scan(&inviterID, &expiresAt, &usedAt)

	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error":   "invalid invite code",
			"message": "This invite code does not exist. You need an invite from an existing member to join.",
		})
		return
	}

	if usedAt != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error":   "invite already used",
			"message": "This invite code has already been used.",
		})
		return
	}

	if expiresAt.Before(time.Now().UTC()) {
		c.JSON(http.StatusBadRequest, gin.H{
			"error":   "invite expired",
			"message": "This invite code has expired. Ask your contact for a new one.",
		})
		return
	}

	// Create new user with initial trust score
	userID := uuid.New().String()
	now := time.Now().UTC()

	_, err = h.db.Pool().Exec(ctx,
		`INSERT INTO users (id, public_key, created_at, trust_score, is_verified, invited_by, invite_code_used)
		 VALUES ($1, $2, $3, $4, false, $5, $6)`,
		userID, pubKeyBytes, now, InitialTrustScore, inviterID, req.InviteCode,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create user"})
		return
	}

	// Mark invite code as used
	_, err = h.db.Pool().Exec(ctx,
		`UPDATE invite_codes SET used_at = $1, invitee_id = $2 WHERE code = $3`,
		now, userID, req.InviteCode,
	)
	if err != nil {
		// Log but don't fail - user was created
		// In production, this should be a transaction
	}

	// Create automatic vouch from inviter (type = 'invite')
	_, err = h.db.Pool().Exec(ctx,
		`INSERT INTO vouches (voucher_id, vouchee_id, created_at, vouch_type)
		 VALUES ($1, $2, $3, 'invite')
		 ON CONFLICT (voucher_id, vouchee_id) DO NOTHING`,
		inviterID, userID, now,
	)
	if err != nil {
		// Log but don't fail - user was created
	}

	// Create challenge for the new user
	challenge, err := h.createChallenge(ctx, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create challenge"})
		return
	}

	c.JSON(http.StatusCreated, RegisterResponse{
		UserID:     userID,
		Challenge:  challenge,
		TrustScore: InitialTrustScore,
	})
}

// ChallengeRequest is the request body for getting a new challenge
type ChallengeRequest struct {
	PublicKey string `json:"public_key" binding:"required"`
}

// ChallengeResponse is the response containing the challenge
type ChallengeResponse struct {
	UserID    string `json:"user_id"`
	Challenge string `json:"challenge"`
	ExpiresAt int64  `json:"expires_at"`
}

// Challenge creates a new authentication challenge for a user
func (h *Handler) Challenge(c *gin.Context) {
	var req ChallengeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Decode public key
	pubKeyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
	if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key"})
		return
	}

	// Find user by public key
	ctx := c.Request.Context()
	var userID string
	err = h.db.Pool().QueryRow(ctx,
		"SELECT id FROM users WHERE public_key = $1",
		pubKeyBytes,
	).Scan(&userID)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	// Create challenge
	challenge, err := h.createChallenge(ctx, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create challenge"})
		return
	}

	c.JSON(http.StatusOK, ChallengeResponse{
		UserID:    userID,
		Challenge: challenge,
		ExpiresAt: time.Now().Add(5 * time.Minute).Unix(),
	})
}

// VerifyRequest is the request body for verifying a signed challenge
type VerifyRequest struct {
	UserID    string `json:"user_id" binding:"required"`
	Challenge string `json:"challenge" binding:"required"`
	Signature string `json:"signature" binding:"required"` // Base64 encoded signature
}

// VerifyResponse is the response containing the JWT token
type VerifyResponse struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expires_at"`
}

// Verify validates a signed challenge and returns a JWT token
func (h *Handler) Verify(c *gin.Context) {
	var req VerifyRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	ctx := c.Request.Context()

	// Get user's public key and trust score
	var pubKeyBytes []byte
	var trustScore int
	err := h.db.Pool().QueryRow(ctx,
		"SELECT public_key, trust_score FROM users WHERE id = $1",
		req.UserID,
	).Scan(&pubKeyBytes, &trustScore)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	// Verify the challenge exists and hasn't been used
	var challengeData string
	err = h.db.Pool().QueryRow(ctx,
		`SELECT challenge FROM auth_challenges
		 WHERE user_id = $1 AND challenge = $2 AND expires_at > $3 AND used_at IS NULL`,
		req.UserID, req.Challenge, time.Now().UTC(),
	).Scan(&challengeData)

	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired challenge"})
		return
	}

	// Decode signature
	signatureBytes, err := base64.StdEncoding.DecodeString(req.Signature)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid signature encoding"})
		return
	}

	// Verify signature
	pubKey := ed25519.PublicKey(pubKeyBytes)
	if !ed25519.Verify(pubKey, []byte(req.Challenge), signatureBytes) {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid signature"})
		return
	}

	// Mark challenge as used
	_, err = h.db.Pool().Exec(ctx,
		"UPDATE auth_challenges SET used_at = $1 WHERE user_id = $2 AND challenge = $3",
		time.Now().UTC(), req.UserID, req.Challenge,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to mark challenge as used"})
		return
	}

	// Generate JWT token
	expiresAt := time.Now().Add(time.Duration(h.cfg.TokenDuration) * time.Hour)
	claims := jwt.MapClaims{
		"sub":         req.UserID,
		"trust_score": trustScore,
		"exp":         expiresAt.Unix(),
		"iat":         time.Now().Unix(),
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenString, err := token.SignedString(h.cfg.JWTSecret)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate token"})
		return
	}

	c.JSON(http.StatusOK, VerifyResponse{
		Token:     tokenString,
		ExpiresAt: expiresAt.Unix(),
	})
}

// GetCurrentUser returns the current user's information
func (h *Handler) GetCurrentUser(c *gin.Context) {
	userID := c.GetString("user_id")

	ctx := c.Request.Context()
	var trustScore int
	var isVerified bool
	var createdAt time.Time

	err := h.db.Pool().QueryRow(ctx,
		"SELECT trust_score, is_verified, created_at FROM users WHERE id = $1",
		userID,
	).Scan(&trustScore, &isVerified, &createdAt)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	// Count vouches received
	var vouchCount int
	h.db.Pool().QueryRow(ctx,
		"SELECT COUNT(*) FROM vouches WHERE vouchee_id = $1",
		userID,
	).Scan(&vouchCount)

	c.JSON(http.StatusOK, gin.H{
		"id":          userID,
		"trust_score": trustScore,
		"is_verified": isVerified,
		"created_at":  createdAt,
		"vouch_count": vouchCount,
	})
}

// DeleteAccount permanently deletes the user's account
func (h *Handler) DeleteAccount(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	// Delete in order (foreign key constraints)
	queries := []string{
		"DELETE FROM alert_responses WHERE user_id = $1",
		"DELETE FROM alerts WHERE author_id = $1",
		"DELETE FROM event_rsvps WHERE user_id = $1",
		"DELETE FROM events WHERE organizer_id = $1",
		"DELETE FROM post_topics WHERE post_id IN (SELECT id FROM posts WHERE author_id = $1)",
		"DELETE FROM posts WHERE author_id = $1",
		"DELETE FROM subscriptions WHERE user_id = $1",
		"DELETE FROM vouches WHERE voucher_id = $1 OR vouchee_id = $1",
		"DELETE FROM auth_challenges WHERE user_id = $1",
		"DELETE FROM users WHERE id = $1",
	}

	for _, query := range queries {
		if _, err := h.db.Pool().Exec(ctx, query, userID); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete account"})
			return
		}
	}

	c.JSON(http.StatusOK, gin.H{"message": "account deleted"})
}

// Vouch vouches for another user (web of trust)
func (h *Handler) Vouch(c *gin.Context) {
	voucherID := c.GetString("user_id")
	voucheeID := c.Param("user_id")

	if voucherID == voucheeID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot vouch for yourself"})
		return
	}

	// Check voucher's trust score (must have minimum trust to vouch)
	ctx := c.Request.Context()
	var voucherTrust int
	err := h.db.Pool().QueryRow(ctx,
		"SELECT trust_score FROM users WHERE id = $1",
		voucherID,
	).Scan(&voucherTrust)

	if err != nil || voucherTrust < 30 {
		c.JSON(http.StatusForbidden, gin.H{
			"error":    "insufficient trust to vouch for others",
			"required": 30,
			"current":  voucherTrust,
		})
		return
	}

	// Check vouchee exists
	var exists bool
	err = h.db.Pool().QueryRow(ctx,
		"SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)",
		voucheeID,
	).Scan(&exists)

	if err != nil || !exists {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	// Create vouch (ignore if already exists)
	_, err = h.db.Pool().Exec(ctx,
		`INSERT INTO vouches (voucher_id, vouchee_id, created_at)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (voucher_id, vouchee_id) DO NOTHING`,
		voucherID, voucheeID, time.Now().UTC(),
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create vouch"})
		return
	}

	// Update vouchee's trust score
	_, err = h.db.Pool().Exec(ctx,
		`UPDATE users SET trust_score = (
			SELECT COUNT(*) * 10 FROM vouches WHERE vouchee_id = $1
		) WHERE id = $1`,
		voucheeID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update trust score"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "vouch recorded"})
}

// GetVouches returns vouches received and given
func (h *Handler) GetVouches(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	// Get vouches received
	rows, err := h.db.Pool().Query(ctx,
		`SELECT v.voucher_id, v.created_at
		 FROM vouches v WHERE v.vouchee_id = $1
		 ORDER BY v.created_at DESC`,
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to get vouches"})
		return
	}
	defer rows.Close()

	var received []gin.H
	for rows.Next() {
		var voucherID string
		var createdAt time.Time
		if err := rows.Scan(&voucherID, &createdAt); err == nil {
			received = append(received, gin.H{
				"from":       voucherID,
				"created_at": createdAt,
			})
		}
	}

	// Get vouches given
	rows, err = h.db.Pool().Query(ctx,
		`SELECT v.vouchee_id, v.created_at
		 FROM vouches v WHERE v.voucher_id = $1
		 ORDER BY v.created_at DESC`,
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to get vouches"})
		return
	}
	defer rows.Close()

	var given []gin.H
	for rows.Next() {
		var voucheeID string
		var createdAt time.Time
		if err := rows.Scan(&voucheeID, &createdAt); err == nil {
			given = append(given, gin.H{
				"to":         voucheeID,
				"created_at": createdAt,
			})
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"received": received,
		"given":    given,
	})
}

// createChallenge generates and stores a new challenge for authentication
func (h *Handler) createChallenge(ctx context.Context, userID string) (string, error) {
	// Generate random challenge
	challengeBytes := make([]byte, 32)
	if _, err := rand.Read(challengeBytes); err != nil {
		return "", err
	}
	challenge := hex.EncodeToString(challengeBytes)

	// Store challenge with expiration
	expiresAt := time.Now().UTC().Add(5 * time.Minute)
	_, err := h.db.Pool().Exec(ctx,
		`INSERT INTO auth_challenges (user_id, challenge, expires_at)
		 VALUES ($1, $2, $3)`,
		userID, challenge, expiresAt,
	)

	return challenge, err
}
