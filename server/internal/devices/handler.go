package devices

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles device management endpoints
type Handler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewHandler creates a new devices handler
func NewHandler(cfg *config.Config, db *storage.Postgres) *Handler {
	return &Handler{cfg: cfg, db: db}
}

// Device represents a user's device
type Device struct {
	ID           string     `json:"id"`
	UserID       string     `json:"user_id"`
	DeviceType   string     `json:"device_type"`
	DeviceName   string     `json:"device_name,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
	LastActiveAt *time.Time `json:"last_active_at,omitempty"`
	IsActive     bool       `json:"is_active"`
}

// SubmitLinkRequest is the request body for submitting a device link payload
type SubmitLinkRequest struct {
	DeviceID         string `json:"device_id" binding:"required"`
	EncryptedPayload string `json:"encrypted_payload" binding:"required"`
}

// RegisterDeviceRequest is the request body for registering a new device
type RegisterDeviceRequest struct {
	DeviceType string `json:"device_type" binding:"required"`
	DeviceName string `json:"device_name"`
}

// SubmitLink handles POST /devices/link — mobile submits encrypted key payload
func (h *Handler) SubmitLink(c *gin.Context) {
	// This endpoint is authenticated (mobile user submitting their encrypted keys)
	var req SubmitLinkRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body", "details": err.Error()})
		return
	}

	// Parse device_id as UUID
	deviceID, err := uuid.Parse(req.DeviceID)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid device_id format"})
		return
	}

	// Store the encrypted payload for the desktop to pick up
	expiresAt := time.Now().Add(5 * time.Minute)
	_, err = h.db.Pool().Exec(c.Request.Context(),
		`INSERT INTO device_link_requests (device_id, encrypted_payload, expires_at)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (device_id) DO UPDATE SET
		   encrypted_payload = EXCLUDED.encrypted_payload,
		   expires_at = EXCLUDED.expires_at,
		   consumed = false`,
		deviceID, req.EncryptedPayload, expiresAt,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to store link request"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"status": "ok", "expires_at": expiresAt})
}

// PollLink handles GET /devices/link/:device_id — desktop polls for encrypted payload
func (h *Handler) PollLink(c *gin.Context) {
	deviceID := c.Param("device_id")
	if _, err := uuid.Parse(deviceID); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid device_id format"})
		return
	}

	var encryptedPayload *string
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`SELECT encrypted_payload FROM device_link_requests
		 WHERE device_id = $1 AND consumed = false AND expires_at > NOW()
		 AND encrypted_payload IS NOT NULL`,
		deviceID,
	).Scan(&encryptedPayload)

	if err != nil {
		// No payload yet — return empty (desktop keeps polling)
		c.JSON(http.StatusOK, gin.H{"encrypted_payload": ""})
		return
	}

	// Mark as consumed so it can't be retrieved again
	_, _ = h.db.Pool().Exec(c.Request.Context(),
		`UPDATE device_link_requests SET consumed = true WHERE device_id = $1`,
		deviceID,
	)

	c.JSON(http.StatusOK, gin.H{"encrypted_payload": *encryptedPayload})
}

// RegisterDevice handles POST /devices/register — register a new device
func (h *Handler) RegisterDevice(c *gin.Context) {
	userID := c.GetString("user_id")

	var req RegisterDeviceRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body", "details": err.Error()})
		return
	}

	// Validate device type
	validTypes := map[string]bool{"ios": true, "android": true, "desktop": true, "web": true}
	if !validTypes[req.DeviceType] {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid device_type; must be ios, android, desktop, or web"})
		return
	}

	var device Device
	err := h.db.Pool().QueryRow(c.Request.Context(),
		`INSERT INTO devices (user_id, device_type, device_name, last_active_at)
		 VALUES ($1, $2, $3, NOW())
		 RETURNING id, user_id, device_type, device_name, created_at, last_active_at, is_active`,
		userID, req.DeviceType, req.DeviceName,
	).Scan(&device.ID, &device.UserID, &device.DeviceType, &device.DeviceName,
		&device.CreatedAt, &device.LastActiveAt, &device.IsActive)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to register device"})
		return
	}

	c.JSON(http.StatusCreated, device)
}

// ListDevices handles GET /devices — list all devices for the current user
func (h *Handler) ListDevices(c *gin.Context) {
	userID := c.GetString("user_id")

	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT id, user_id, device_type, device_name, created_at, last_active_at, is_active
		 FROM devices WHERE user_id = $1 AND is_active = true
		 ORDER BY last_active_at DESC NULLS LAST`,
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to list devices"})
		return
	}
	defer rows.Close()

	var devices []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.UserID, &d.DeviceType, &d.DeviceName,
			&d.CreatedAt, &d.LastActiveAt, &d.IsActive); err != nil {
			continue
		}
		devices = append(devices, d)
	}

	if devices == nil {
		devices = []Device{}
	}

	c.JSON(http.StatusOK, gin.H{"devices": devices})
}

// RemoveDevice handles DELETE /devices/:id — deactivate a device
func (h *Handler) RemoveDevice(c *gin.Context) {
	userID := c.GetString("user_id")
	deviceID := c.Param("id")

	if _, err := uuid.Parse(deviceID); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid device id"})
		return
	}

	result, err := h.db.Pool().Exec(c.Request.Context(),
		`UPDATE devices SET is_active = false WHERE id = $1 AND user_id = $2`,
		deviceID, userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to remove device"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "device not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"status": "removed"})
}
