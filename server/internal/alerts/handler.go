package alerts

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles SOS alert endpoints
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new alerts handler
func NewHandler(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{cfg: cfg, db: db, redis: redis}
}

// CreateAlertRequest represents a new SOS alert
type CreateAlertRequest struct {
	Title        string  `json:"title" binding:"required,max=200"`
	Description  string  `json:"description"`
	Severity     int     `json:"severity" binding:"required,min=1,max=3"` // 1=awareness, 2=help_needed, 3=emergency
	Latitude     float64 `json:"latitude" binding:"required"`
	Longitude    float64 `json:"longitude" binding:"required"`
	LocationName string  `json:"location_name"`
	RadiusMeters int     `json:"radius_meters"` // Broadcast radius
}

// ListAlerts returns active alerts
func (h *Handler) ListAlerts(c *gin.Context) {
	ctx := c.Request.Context()

	// Parse filters
	status := c.DefaultQuery("status", "active")
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))

	if limit > 100 {
		limit = 100
	}

	rows, err := h.db.Pool().Query(ctx, `
		SELECT a.id, a.author_id, a.title, a.description, a.severity,
			   ST_Y(a.location::geometry) as lat, ST_X(a.location::geometry) as lon,
			   a.location_name, a.radius_meters, a.status, a.created_at,
			   (SELECT COUNT(*) FROM alert_responses WHERE alert_id = a.id) as response_count
		FROM alerts a
		WHERE a.status = $1
		ORDER BY a.severity DESC, a.created_at DESC
		LIMIT $2
	`, status, limit)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch alerts"})
		return
	}
	defer rows.Close()

	var alerts []gin.H
	for rows.Next() {
		var id, authorID, title, status string
		var description, locationName *string
		var severity, radiusMeters, responseCount int
		var lat, lon float64
		var createdAt time.Time

		if err := rows.Scan(&id, &authorID, &title, &description, &severity, &lat, &lon, &locationName, &radiusMeters, &status, &createdAt, &responseCount); err != nil {
			continue
		}

		alert := gin.H{
			"id":             id,
			"author_id":      authorID,
			"title":          title,
			"severity":       severity,
			"location":       gin.H{"latitude": lat, "longitude": lon},
			"radius_meters":  radiusMeters,
			"status":         status,
			"created_at":     createdAt,
			"response_count": responseCount,
		}

		if description != nil {
			alert["description"] = *description
		}
		if locationName != nil {
			alert["location_name"] = *locationName
		}

		// Add severity label
		switch severity {
		case 1:
			alert["severity_label"] = "awareness"
		case 2:
			alert["severity_label"] = "help_needed"
		case 3:
			alert["severity_label"] = "emergency"
		}

		alerts = append(alerts, alert)
	}

	c.JSON(http.StatusOK, gin.H{"alerts": alerts})
}

// CreateAlert creates a new SOS alert (verified users only)
func (h *Handler) CreateAlert(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	// Check if user is verified (trusted to send SOS alerts)
	var isVerified bool
	var trustScore int
	err := h.db.Pool().QueryRow(ctx,
		"SELECT is_verified, trust_score FROM users WHERE id = $1",
		userID,
	).Scan(&isVerified, &trustScore)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to verify user"})
		return
	}

	// Require either verified status or high trust score
	if !isVerified && trustScore < 100 {
		c.JSON(http.StatusForbidden, gin.H{
			"error":   "only verified users or users with high trust can create SOS alerts",
			"message": "Get vouched by more trusted members to increase your trust score",
		})
		return
	}

	var req CreateAlertRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	alertID := uuid.New().String()

	// Default radius if not specified
	if req.RadiusMeters == 0 {
		req.RadiusMeters = 5000 // 5km default
	}
	if req.RadiusMeters > 50000 {
		req.RadiusMeters = 50000 // Max 50km
	}

	locationSQL := "POINT(" + strconv.FormatFloat(req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(req.Latitude, 'f', 6, 64) + ")"

	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO alerts (id, author_id, title, description, severity, location, location_name, radius_meters)
		VALUES ($1, $2, $3, $4, $5, ST_GeogFromText($6), $7, $8)
	`, alertID, userID, req.Title, req.Description, req.Severity, locationSQL, req.LocationName, req.RadiusMeters)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create alert"})
		return
	}

	// TODO: Trigger push notifications to users within radius
	// This would be done via Redis pub/sub and a separate notification service

	// Publish alert to Redis for real-time notification
	h.redis.Publish(ctx, "alerts:new", alertID)

	c.JSON(http.StatusCreated, gin.H{
		"id":      alertID,
		"message": "alert created and broadcasting to nearby users",
	})
}

// GetAlert returns a single alert with responses
func (h *Handler) GetAlert(c *gin.Context) {
	alertID := c.Param("id")
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	var id, authorID, title, status string
	var description, locationName *string
	var severity, radiusMeters int
	var lat, lon float64
	var createdAt time.Time
	var resolvedAt *time.Time

	err := h.db.Pool().QueryRow(ctx, `
		SELECT a.id, a.author_id, a.title, a.description, a.severity,
			   ST_Y(a.location::geometry), ST_X(a.location::geometry),
			   a.location_name, a.radius_meters, a.status, a.created_at, a.resolved_at
		FROM alerts a
		WHERE a.id = $1
	`, alertID).Scan(&id, &authorID, &title, &description, &severity, &lat, &lon, &locationName, &radiusMeters, &status, &createdAt, &resolvedAt)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "alert not found"})
		return
	}

	// Get responses
	rows, err := h.db.Pool().Query(ctx, `
		SELECT ar.user_id, ar.status, ar.eta_minutes, ar.created_at
		FROM alert_responses ar
		WHERE ar.alert_id = $1
		ORDER BY ar.created_at ASC
	`, alertID)

	var responses []gin.H
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var respUserID, respStatus string
			var eta *int
			var respCreatedAt time.Time

			if err := rows.Scan(&respUserID, &respStatus, &eta, &respCreatedAt); err == nil {
				resp := gin.H{
					"user_id":    respUserID,
					"status":     respStatus,
					"created_at": respCreatedAt,
				}
				if eta != nil {
					resp["eta_minutes"] = *eta
				}
				responses = append(responses, resp)
			}
		}
	}

	// Check if current user has responded
	var userResponse *string
	h.db.Pool().QueryRow(ctx,
		"SELECT status FROM alert_responses WHERE alert_id = $1 AND user_id = $2",
		alertID, userID,
	).Scan(&userResponse)

	alert := gin.H{
		"id":            id,
		"author_id":     authorID,
		"title":         title,
		"severity":      severity,
		"location":      gin.H{"latitude": lat, "longitude": lon},
		"radius_meters": radiusMeters,
		"status":        status,
		"created_at":    createdAt,
		"responses":     responses,
	}

	if description != nil {
		alert["description"] = *description
	}
	if locationName != nil {
		alert["location_name"] = *locationName
	}
	if resolvedAt != nil {
		alert["resolved_at"] = *resolvedAt
	}
	if userResponse != nil {
		alert["user_response"] = *userResponse
	}

	c.JSON(http.StatusOK, alert)
}

// UpdateAlertStatus updates the status of an alert (author only)
func (h *Handler) UpdateAlertStatus(c *gin.Context) {
	userID := c.GetString("user_id")
	alertID := c.Param("id")
	ctx := c.Request.Context()

	var req struct {
		Status string `json:"status" binding:"required,oneof=active resolved false_alarm"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Verify ownership
	var authorID string
	err := h.db.Pool().QueryRow(ctx, "SELECT author_id FROM alerts WHERE id = $1", alertID).Scan(&authorID)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "alert not found"})
		return
	}
	if authorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the author can update alert status"})
		return
	}

	var resolvedAt interface{}
	if req.Status == "resolved" || req.Status == "false_alarm" {
		resolvedAt = time.Now().UTC()
	}

	_, err = h.db.Pool().Exec(ctx,
		"UPDATE alerts SET status = $2, resolved_at = $3 WHERE id = $1",
		alertID, req.Status, resolvedAt,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update alert"})
		return
	}

	// Notify responders of status change
	h.redis.Publish(ctx, "alerts:updated", alertID)

	c.JSON(http.StatusOK, gin.H{"message": "alert status updated", "status": req.Status})
}

// RespondToAlert creates or updates a response to an alert
func (h *Handler) RespondToAlert(c *gin.Context) {
	userID := c.GetString("user_id")
	alertID := c.Param("id")
	ctx := c.Request.Context()

	var req struct {
		Status     string   `json:"status" binding:"required,oneof=acknowledged en_route arrived unable"`
		ETAMinutes *int     `json:"eta_minutes"`
		Latitude   *float64 `json:"latitude"`
		Longitude  *float64 `json:"longitude"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Verify alert exists and is active
	var alertStatus string
	err := h.db.Pool().QueryRow(ctx, "SELECT status FROM alerts WHERE id = $1", alertID).Scan(&alertStatus)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "alert not found"})
		return
	}
	if alertStatus != "active" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "alert is no longer active"})
		return
	}

	// Build location if provided
	var locationSQL interface{}
	if req.Latitude != nil && req.Longitude != nil {
		locationSQL = "POINT(" + strconv.FormatFloat(*req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(*req.Latitude, 'f', 6, 64) + ")"
	}

	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO alert_responses (alert_id, user_id, status, eta_minutes, location)
		VALUES ($1, $2, $3, $4, ST_GeogFromText($5))
		ON CONFLICT (alert_id, user_id) DO UPDATE SET
			status = $3,
			eta_minutes = $4,
			location = ST_GeogFromText($5),
			updated_at = NOW()
	`, alertID, userID, req.Status, req.ETAMinutes, locationSQL)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to record response"})
		return
	}

	// Notify alert author of new response
	h.redis.Publish(ctx, "alerts:response:"+alertID, userID)

	c.JSON(http.StatusOK, gin.H{"message": "response recorded", "status": req.Status})
}

// GetNearbyAlerts returns active alerts near a location
func (h *Handler) GetNearbyAlerts(c *gin.Context) {
	ctx := c.Request.Context()

	lat, err := strconv.ParseFloat(c.Query("latitude"), 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "latitude is required"})
		return
	}

	lon, err := strconv.ParseFloat(c.Query("longitude"), 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "longitude is required"})
		return
	}

	// Get alerts where user is within broadcast radius
	rows, err := h.db.Pool().Query(ctx, `
		SELECT a.id, a.title, a.severity,
			   ST_Y(a.location::geometry) as lat, ST_X(a.location::geometry) as lon,
			   a.location_name, a.radius_meters, a.created_at,
			   ST_Distance(a.location, ST_MakePoint($2, $1)::geography) as distance_meters,
			   (SELECT COUNT(*) FROM alert_responses WHERE alert_id = a.id) as response_count
		FROM alerts a
		WHERE a.status = 'active'
		  AND ST_DWithin(a.location, ST_MakePoint($2, $1)::geography, a.radius_meters)
		ORDER BY a.severity DESC, distance_meters ASC
		LIMIT 20
	`, lat, lon)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch nearby alerts"})
		return
	}
	defer rows.Close()

	var alerts []gin.H
	for rows.Next() {
		var id, title string
		var locationName *string
		var severity, radiusMeters, responseCount int
		var alertLat, alertLon, distance float64
		var createdAt time.Time

		if err := rows.Scan(&id, &title, &severity, &alertLat, &alertLon, &locationName, &radiusMeters, &createdAt, &distance, &responseCount); err != nil {
			continue
		}

		alert := gin.H{
			"id":              id,
			"title":           title,
			"severity":        severity,
			"location":        gin.H{"latitude": alertLat, "longitude": alertLon},
			"radius_meters":   radiusMeters,
			"distance_meters": int(distance),
			"created_at":      createdAt,
			"response_count":  responseCount,
		}

		if locationName != nil {
			alert["location_name"] = *locationName
		}

		// Add severity label
		switch severity {
		case 1:
			alert["severity_label"] = "awareness"
		case 2:
			alert["severity_label"] = "help_needed"
		case 3:
			alert["severity_label"] = "emergency"
		}

		alerts = append(alerts, alert)
	}

	c.JSON(http.StatusOK, gin.H{
		"alerts": alerts,
		"center": gin.H{"latitude": lat, "longitude": lon},
	})
}
