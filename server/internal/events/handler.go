package events

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles event-related endpoints
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new events handler
func NewHandler(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{cfg: cfg, db: db, redis: redis}
}

// CreateEventRequest represents a new event
type CreateEventRequest struct {
	Title        string   `json:"title" binding:"required,max=200"`
	Description  string   `json:"description"`
	EventType    string   `json:"event_type" binding:"required,oneof=protest strike fundraiser mutual_aid meeting other"`
	Latitude     float64  `json:"latitude" binding:"required"`
	Longitude    float64  `json:"longitude" binding:"required"`
	LocationName string   `json:"location_name"`
	StartsAt     int64    `json:"starts_at" binding:"required"` // Unix timestamp
	EndsAt       *int64   `json:"ends_at"`
	TopicIDs     []string `json:"topic_ids"`
}

// ListEvents returns upcoming events
func (h *Handler) ListEvents(c *gin.Context) {
	ctx := c.Request.Context()

	// Parse filters
	eventType := c.Query("type")
	topicID := c.Query("topic_id")
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

	if limit > 100 {
		limit = 100
	}

	// Base query
	query := `
		SELECT e.id, e.organizer_id, e.title, e.description, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.starts_at, e.ends_at, e.is_cancelled,
			   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count
		FROM events e
		WHERE e.starts_at > NOW() - INTERVAL '1 day'
		  AND e.is_cancelled = false
	`

	args := []interface{}{}
	argCount := 0

	if eventType != "" {
		argCount++
		query += " AND e.event_type = $" + strconv.Itoa(argCount)
		args = append(args, eventType)
	}

	if topicID != "" {
		argCount++
		query += " AND EXISTS (SELECT 1 FROM event_topics WHERE event_id = e.id AND topic_id = $" + strconv.Itoa(argCount) + ")"
		args = append(args, topicID)
	}

	query += " ORDER BY e.starts_at ASC"
	argCount++
	query += " LIMIT $" + strconv.Itoa(argCount)
	args = append(args, limit)
	argCount++
	query += " OFFSET $" + strconv.Itoa(argCount)
	args = append(args, offset)

	rows, err := h.db.Pool().Query(ctx, query, args...)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch events"})
		return
	}
	defer rows.Close()

	var events []gin.H
	for rows.Next() {
		var id, organizerID, title, eventType string
		var description, locationName *string
		var lat, lon float64
		var startsAt time.Time
		var endsAt *time.Time
		var isCancelled bool
		var rsvpCount int

		if err := rows.Scan(&id, &organizerID, &title, &description, &eventType, &lat, &lon, &locationName, &startsAt, &endsAt, &isCancelled, &rsvpCount); err != nil {
			continue
		}

		event := gin.H{
			"id":           id,
			"organizer_id": organizerID,
			"title":        title,
			"event_type":   eventType,
			"location":     gin.H{"latitude": lat, "longitude": lon},
			"starts_at":    startsAt,
			"rsvp_count":   rsvpCount,
		}

		if description != nil {
			event["description"] = *description
		}
		if locationName != nil {
			event["location_name"] = *locationName
		}
		if endsAt != nil {
			event["ends_at"] = *endsAt
		}

		events = append(events, event)
	}

	c.JSON(http.StatusOK, gin.H{
		"events": events,
		"limit":  limit,
		"offset": offset,
	})
}

// CreateEvent creates a new event
func (h *Handler) CreateEvent(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := c.GetFloat64("trust_score")

	// Require trust score of 50 to create events
	if trustScore < 50 {
		c.JSON(http.StatusForbidden, gin.H{
			"error":    "insufficient trust level to create events",
			"required": 50,
			"current":  int(trustScore),
		})
		return
	}

	var req CreateEventRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ctx := c.Request.Context()
	eventID := uuid.New().String()

	startsAt := time.Unix(req.StartsAt, 0)
	var endsAt *time.Time
	if req.EndsAt != nil {
		t := time.Unix(*req.EndsAt, 0)
		endsAt = &t
	}

	locationSQL := "POINT(" + strconv.FormatFloat(req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(req.Latitude, 'f', 6, 64) + ")"

	_, err := h.db.Pool().Exec(ctx, `
		INSERT INTO events (id, organizer_id, title, description, event_type, location, location_name, starts_at, ends_at)
		VALUES ($1, $2, $3, $4, $5, ST_GeogFromText($6), $7, $8, $9)
	`, eventID, userID, req.Title, req.Description, req.EventType, locationSQL, req.LocationName, startsAt, endsAt)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create event"})
		return
	}

	// Add topic associations
	for _, topicID := range req.TopicIDs {
		h.db.Pool().Exec(ctx, `
			INSERT INTO event_topics (event_id, topic_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, eventID, topicID)
	}

	c.JSON(http.StatusCreated, gin.H{
		"id":      eventID,
		"message": "event created",
	})
}

// GetEvent returns a single event
func (h *Handler) GetEvent(c *gin.Context) {
	eventID := c.Param("id")
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	var id, organizerID, title, eventType string
	var description, locationName *string
	var lat, lon float64
	var startsAt time.Time
	var endsAt *time.Time
	var isCancelled bool

	err := h.db.Pool().QueryRow(ctx, `
		SELECT e.id, e.organizer_id, e.title, e.description, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.starts_at, e.ends_at, e.is_cancelled
		FROM events e
		WHERE e.id = $1
	`, eventID).Scan(&id, &organizerID, &title, &description, &eventType, &lat, &lon, &locationName, &startsAt, &endsAt, &isCancelled)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "event not found"})
		return
	}

	// Get RSVP count
	var rsvpCount int
	h.db.Pool().QueryRow(ctx, "SELECT COUNT(*) FROM event_rsvps WHERE event_id = $1 AND status = 'going'", eventID).Scan(&rsvpCount)

	// Check if current user has RSVP'd
	var userRSVP *string
	h.db.Pool().QueryRow(ctx, "SELECT status FROM event_rsvps WHERE event_id = $1 AND user_id = $2", eventID, userID).Scan(&userRSVP)

	event := gin.H{
		"id":           id,
		"organizer_id": organizerID,
		"title":        title,
		"event_type":   eventType,
		"location":     gin.H{"latitude": lat, "longitude": lon},
		"starts_at":    startsAt,
		"is_cancelled": isCancelled,
		"rsvp_count":   rsvpCount,
	}

	if description != nil {
		event["description"] = *description
	}
	if locationName != nil {
		event["location_name"] = *locationName
	}
	if endsAt != nil {
		event["ends_at"] = *endsAt
	}
	if userRSVP != nil {
		event["user_rsvp"] = *userRSVP
	}

	c.JSON(http.StatusOK, event)
}

// UpdateEvent updates an event (organizer only)
func (h *Handler) UpdateEvent(c *gin.Context) {
	userID := c.GetString("user_id")
	eventID := c.Param("id")
	ctx := c.Request.Context()

	// Verify ownership
	var organizerID string
	err := h.db.Pool().QueryRow(ctx, "SELECT organizer_id FROM events WHERE id = $1", eventID).Scan(&organizerID)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "event not found"})
		return
	}
	if organizerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the organizer can update this event"})
		return
	}

	var req struct {
		Title        *string `json:"title"`
		Description  *string `json:"description"`
		LocationName *string `json:"location_name"`
		StartsAt     *int64  `json:"starts_at"`
		EndsAt       *int64  `json:"ends_at"`
		IsCancelled  *bool   `json:"is_cancelled"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Build update query
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE events SET
			title = COALESCE($3, title),
			description = COALESCE($4, description),
			location_name = COALESCE($5, location_name),
			is_cancelled = COALESCE($6, is_cancelled),
			updated_at = NOW()
		WHERE id = $1 AND organizer_id = $2
	`, eventID, userID, req.Title, req.Description, req.LocationName, req.IsCancelled)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update event"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "event updated"})
}

// DeleteEvent deletes an event (organizer only)
func (h *Handler) DeleteEvent(c *gin.Context) {
	userID := c.GetString("user_id")
	eventID := c.Param("id")
	ctx := c.Request.Context()

	result, err := h.db.Pool().Exec(ctx,
		"DELETE FROM events WHERE id = $1 AND organizer_id = $2",
		eventID, userID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete event"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "event not found or unauthorized"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "event deleted"})
}

// RSVP creates or updates an RSVP for an event
func (h *Handler) RSVP(c *gin.Context) {
	userID := c.GetString("user_id")
	eventID := c.Param("id")
	ctx := c.Request.Context()

	var req struct {
		Status string `json:"status" binding:"required,oneof=going interested not_going"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Verify event exists
	var exists bool
	err := h.db.Pool().QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM events WHERE id = $1)", eventID).Scan(&exists)
	if err != nil || !exists {
		c.JSON(http.StatusNotFound, gin.H{"error": "event not found"})
		return
	}

	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO event_rsvps (event_id, user_id, status)
		VALUES ($1, $2, $3)
		ON CONFLICT (event_id, user_id) DO UPDATE SET status = $3
	`, eventID, userID, req.Status)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to record RSVP"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "RSVP recorded", "status": req.Status})
}

// CancelRSVP removes an RSVP
func (h *Handler) CancelRSVP(c *gin.Context) {
	userID := c.GetString("user_id")
	eventID := c.Param("id")
	ctx := c.Request.Context()

	_, err := h.db.Pool().Exec(ctx,
		"DELETE FROM event_rsvps WHERE event_id = $1 AND user_id = $2",
		eventID, userID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to cancel RSVP"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "RSVP cancelled"})
}

// GetNearbyEvents returns events near a location
func (h *Handler) GetNearbyEvents(c *gin.Context) {
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

	radiusMeters, _ := strconv.Atoi(c.DefaultQuery("radius", "10000"))
	if radiusMeters > 100000 {
		radiusMeters = 100000 // Max 100km
	}

	rows, err := h.db.Pool().Query(ctx, `
		SELECT e.id, e.title, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.starts_at,
			   ST_Distance(e.location, ST_MakePoint($2, $1)::geography) as distance_meters,
			   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count
		FROM events e
		WHERE e.starts_at > NOW()
		  AND e.is_cancelled = false
		  AND ST_DWithin(e.location, ST_MakePoint($2, $1)::geography, $3)
		ORDER BY e.starts_at ASC
		LIMIT 50
	`, lat, lon, radiusMeters)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch nearby events"})
		return
	}
	defer rows.Close()

	var events []gin.H
	for rows.Next() {
		var id, title, eventType string
		var eventLat, eventLon, distance float64
		var locationName *string
		var startsAt time.Time
		var rsvpCount int

		if err := rows.Scan(&id, &title, &eventType, &eventLat, &eventLon, &locationName, &startsAt, &distance, &rsvpCount); err != nil {
			continue
		}

		event := gin.H{
			"id":              id,
			"title":           title,
			"event_type":      eventType,
			"location":        gin.H{"latitude": eventLat, "longitude": eventLon},
			"starts_at":       startsAt,
			"distance_meters": int(distance),
			"rsvp_count":      rsvpCount,
		}

		if locationName != nil {
			event["location_name"] = *locationName
		}

		events = append(events, event)
	}

	c.JSON(http.StatusOK, gin.H{
		"events": events,
		"center": gin.H{"latitude": lat, "longitude": lon},
		"radius": radiusMeters,
	})
}
