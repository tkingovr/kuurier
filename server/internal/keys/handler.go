package keys

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles Signal key management endpoints
type Handler struct {
	cfg     *config.Config
	db      *storage.Postgres
	service *Service
}

// NewHandler creates a new keys handler
func NewHandler(cfg *config.Config, db *storage.Postgres) *Handler {
	return &Handler{
		cfg:     cfg,
		db:      db,
		service: NewService(db),
	}
}

// UploadBundleRequest is the request body for uploading a key bundle
type UploadBundleRequest struct {
	IdentityKey    string   `json:"identity_key" binding:"required"`    // Base64 encoded public identity key
	RegistrationID int      `json:"registration_id" binding:"required"` // Signal registration ID
	SignedPreKey   SignedPreKeyRequest `json:"signed_prekey" binding:"required"`
	PreKeys        []PreKeyRequest `json:"prekeys"` // Optional batch of one-time pre-keys
}

// SignedPreKeyRequest represents a signed pre-key in requests
type SignedPreKeyRequest struct {
	KeyID     int    `json:"key_id" binding:"required"`
	PublicKey string `json:"public_key" binding:"required"` // Base64 encoded
	Signature string `json:"signature" binding:"required"`  // Base64 encoded
}

// PreKeyRequest represents a one-time pre-key in requests
type PreKeyRequest struct {
	KeyID     int    `json:"key_id" binding:"required"`
	PublicKey string `json:"public_key" binding:"required"` // Base64 encoded
}

// UploadBundle uploads identity key, signed pre-key, and optionally one-time pre-keys
func (h *Handler) UploadBundle(c *gin.Context) {
	userID := c.GetString("user_id")

	var req UploadBundleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body", "details": err.Error()})
		return
	}

	// Convert request to internal types
	bundle := &KeyBundle{
		IdentityKey:    req.IdentityKey,
		RegistrationID: req.RegistrationID,
		SignedPreKey: SignedPreKey{
			KeyID:     req.SignedPreKey.KeyID,
			PublicKey: req.SignedPreKey.PublicKey,
			Signature: req.SignedPreKey.Signature,
		},
	}

	for _, pk := range req.PreKeys {
		bundle.PreKeys = append(bundle.PreKeys, PreKey{
			KeyID:     pk.KeyID,
			PublicKey: pk.PublicKey,
		})
	}

	ctx := c.Request.Context()
	if err := h.service.UploadBundle(ctx, userID, bundle); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to upload key bundle", "details": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message":      "key bundle uploaded",
		"prekey_count": len(req.PreKeys),
	})
}

// PreKeyBundleResponse is the response for fetching a user's key bundle
type PreKeyBundleResponse struct {
	IdentityKey    string `json:"identity_key"`
	RegistrationID int    `json:"registration_id"`
	SignedPreKey   SignedPreKeyResponse `json:"signed_prekey"`
	PreKey         *PreKeyResponse `json:"prekey,omitempty"` // May be nil if no pre-keys left
}

// SignedPreKeyResponse represents a signed pre-key in responses
type SignedPreKeyResponse struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
	Signature string `json:"signature"`
}

// PreKeyResponse represents a one-time pre-key in responses
type PreKeyResponse struct {
	KeyID     int    `json:"key_id"`
	PublicKey string `json:"public_key"`
}

// GetBundle fetches a user's pre-key bundle (consumes one pre-key)
func (h *Handler) GetBundle(c *gin.Context) {
	targetUserID := c.Param("user_id")
	requestingUserID := c.GetString("user_id")

	// Can't fetch your own bundle (no need for session with yourself)
	if targetUserID == requestingUserID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot fetch your own key bundle"})
		return
	}

	ctx := c.Request.Context()
	bundle, err := h.service.GetBundle(ctx, targetUserID)
	if err != nil {
		if err == ErrNoKeys {
			c.JSON(http.StatusNotFound, gin.H{"error": "user has not uploaded keys"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch key bundle"})
		return
	}

	response := PreKeyBundleResponse{
		IdentityKey:    bundle.IdentityKey,
		RegistrationID: bundle.RegistrationID,
		SignedPreKey: SignedPreKeyResponse{
			KeyID:     bundle.SignedPreKey.KeyID,
			PublicKey: bundle.SignedPreKey.PublicKey,
			Signature: bundle.SignedPreKey.Signature,
		},
	}

	// Include pre-key if available
	if bundle.PreKey != nil {
		response.PreKey = &PreKeyResponse{
			KeyID:     bundle.PreKey.KeyID,
			PublicKey: bundle.PreKey.PublicKey,
		}
	}

	c.JSON(http.StatusOK, response)
}

// UploadPreKeysRequest is the request body for uploading additional pre-keys
type UploadPreKeysRequest struct {
	PreKeys []PreKeyRequest `json:"prekeys" binding:"required,min=1"`
}

// UploadPreKeys uploads additional one-time pre-keys
func (h *Handler) UploadPreKeys(c *gin.Context) {
	userID := c.GetString("user_id")

	var req UploadPreKeysRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Limit batch size to prevent abuse
	if len(req.PreKeys) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "too many pre-keys in single request (max 100)"})
		return
	}

	var preKeys []PreKey
	for _, pk := range req.PreKeys {
		preKeys = append(preKeys, PreKey{
			KeyID:     pk.KeyID,
			PublicKey: pk.PublicKey,
		})
	}

	ctx := c.Request.Context()
	if err := h.service.UploadPreKeys(ctx, userID, preKeys); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to upload pre-keys"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "pre-keys uploaded",
		"count":   len(req.PreKeys),
	})
}

// PreKeyCountResponse is the response for checking pre-key count
type PreKeyCountResponse struct {
	Count     int  `json:"count"`
	LowWarning bool `json:"low_warning"` // True if count < 10
}

// GetPreKeyCount returns the number of remaining pre-keys for the current user
func (h *Handler) GetPreKeyCount(c *gin.Context) {
	userID := c.GetString("user_id")

	ctx := c.Request.Context()
	count, err := h.service.GetPreKeyCount(ctx, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to get pre-key count"})
		return
	}

	c.JSON(http.StatusOK, PreKeyCountResponse{
		Count:      count,
		LowWarning: count < 10,
	})
}

// UpdateSignedPreKey updates the user's signed pre-key (should be done monthly)
type UpdateSignedPreKeyRequest struct {
	SignedPreKey SignedPreKeyRequest `json:"signed_prekey" binding:"required"`
}

// UpdateSignedPreKey updates the user's signed pre-key
func (h *Handler) UpdateSignedPreKey(c *gin.Context) {
	userID := c.GetString("user_id")

	var req UpdateSignedPreKeyRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	signedPreKey := SignedPreKey{
		KeyID:     req.SignedPreKey.KeyID,
		PublicKey: req.SignedPreKey.PublicKey,
		Signature: req.SignedPreKey.Signature,
	}

	ctx := c.Request.Context()
	if err := h.service.UpdateSignedPreKey(ctx, userID, signedPreKey); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update signed pre-key"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "signed pre-key updated"})
}
