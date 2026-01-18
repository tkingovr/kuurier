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
	Title              string   `json:"title" binding:"required,max=200"`
	Description        string   `json:"description"`
	EventType          string   `json:"event_type" binding:"required,oneof=protest strike fundraiser mutual_aid meeting other"`
	Latitude           float64  `json:"latitude" binding:"required"`
	Longitude          float64  `json:"longitude" binding:"required"`
	LocationName       string   `json:"location_name"`
	LocationArea       string   `json:"location_area"`        // General area shown when exact location hidden
	LocationVisibility string   `json:"location_visibility"`  // public, rsvp, timed
	LocationRevealAt   *int64   `json:"location_reveal_at"`   // Unix timestamp for timed visibility
	StartsAt           int64    `json:"starts_at" binding:"required"` // Unix timestamp
	EndsAt             *int64   `json:"ends_at"`
	TopicIDs           []string `json:"topic_ids"`
	EnableChat         *bool    `json:"enable_chat"`          // Whether to create event discussion channel
}

// shouldRevealLocation determines if location should be shown based on visibility settings
func shouldRevealLocation(visibility string, revealAt *time.Time, userID, organizerID string, hasRSVP bool) bool {
	switch visibility {
	case "public":
		return true
	case "rsvp":
		return hasRSVP || userID == organizerID
	case "timed":
		if userID == organizerID {
			return true
		}
		if revealAt != nil && time.Now().After(*revealAt) {
			return true
		}
		// Also reveal if user has RSVP'd
		return hasRSVP
	default:
		return true // Default to public for backward compatibility
	}
}

// ListEvents returns upcoming events
func (h *Handler) ListEvents(c *gin.Context) {
	ctx := c.Request.Context()
	userID := c.GetString("user_id")

	// Parse filters
	eventType := c.Query("type")
	topicID := c.Query("topic_id")
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

	if limit > 100 {
		limit = 100
	}

	// Base query - includes location privacy fields
	query := `
		SELECT e.id, e.organizer_id, e.title, e.description, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.location_area, e.location_visibility, e.location_reveal_at,
			   e.starts_at, e.ends_at, e.is_cancelled,
			   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count,
			   EXISTS(SELECT 1 FROM event_rsvps WHERE event_id = e.id AND user_id = $1) as has_rsvp
		FROM events e
		WHERE e.starts_at > NOW() - INTERVAL '1 day'
		  AND e.is_cancelled = false
	`

	args := []interface{}{userID}
	argCount := 1

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
		var description, locationName, locationArea *string
		var locationVisibility string
		var locationRevealAt *time.Time
		var lat, lon float64
		var startsAt time.Time
		var endsAt *time.Time
		var isCancelled, hasRSVP bool
		var rsvpCount int

		if err := rows.Scan(&id, &organizerID, &title, &description, &eventType, &lat, &lon,
			&locationName, &locationArea, &locationVisibility, &locationRevealAt,
			&startsAt, &endsAt, &isCancelled, &rsvpCount, &hasRSVP); err != nil {
			continue
		}

		event := gin.H{
			"id":                  id,
			"organizer_id":        organizerID,
			"title":               title,
			"event_type":          eventType,
			"starts_at":           startsAt,
			"rsvp_count":          rsvpCount,
			"location_visibility": locationVisibility,
		}

		// Conditionally include exact location
		if shouldRevealLocation(locationVisibility, locationRevealAt, userID, organizerID, hasRSVP) {
			event["location"] = gin.H{"latitude": lat, "longitude": lon}
			if locationName != nil {
				event["location_name"] = *locationName
			}
			event["location_revealed"] = true
		} else {
			event["location_revealed"] = false
			// Show general area if provided
			if locationArea != nil {
				event["location_area"] = *locationArea
			}
			// Show when location will be revealed for timed events
			if locationVisibility == "timed" && locationRevealAt != nil {
				event["location_reveal_at"] = *locationRevealAt
			}
		}

		if description != nil {
			event["description"] = *description
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
	now := time.Now().UTC()

	// Default enableChat to false if not specified
	enableChat := req.EnableChat != nil && *req.EnableChat

	startsAt := time.Unix(req.StartsAt, 0)
	var endsAt *time.Time
	if req.EndsAt != nil {
		t := time.Unix(*req.EndsAt, 0)
		endsAt = &t
	}

	// Default visibility to public
	visibility := req.LocationVisibility
	if visibility == "" {
		visibility = "public"
	}
	if visibility != "public" && visibility != "rsvp" && visibility != "timed" {
		visibility = "public"
	}

	// For timed visibility, default to 1 hour before event if not specified
	var revealAt *time.Time
	if visibility == "timed" {
		if req.LocationRevealAt != nil {
			t := time.Unix(*req.LocationRevealAt, 0)
			revealAt = &t
		} else {
			// Default: reveal 1 hour before event starts
			t := startsAt.Add(-1 * time.Hour)
			revealAt = &t
		}
	}

	locationSQL := "POINT(" + strconv.FormatFloat(req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(req.Latitude, 'f', 6, 64) + ")"

	// Start transaction
	tx, err := h.db.Pool().Begin(ctx)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "database error"})
		return
	}
	defer tx.Rollback(ctx)

	// Create the event first (without channel_id to avoid FK violation)
	_, err = tx.Exec(ctx, `
		INSERT INTO events (id, organizer_id, title, description, event_type, location, location_name,
		                    location_area, location_visibility, location_reveal_at, starts_at, ends_at)
		VALUES ($1, $2, $3, $4, $5, ST_GeogFromText($6), $7, $8, $9, $10, $11, $12)
	`, eventID, userID, req.Title, req.Description, req.EventType, locationSQL,
		req.LocationName, req.LocationArea, visibility, revealAt, startsAt, endsAt)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create event"})
		return
	}

	// Optionally create the event channel
	var channelID string
	if enableChat {
		channelID = uuid.New().String()
		channelName := "Event: " + req.Title
		_, err = tx.Exec(ctx, `
			INSERT INTO channels (id, name, description, type, event_id, created_by, created_at, updated_at)
			VALUES ($1, $2, $3, 'event', $4, $5, $6, $6)
		`, channelID, channelName, req.Description, eventID, userID, now)

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create event channel"})
			return
		}

		// Link the channel back to the event
		_, err = tx.Exec(ctx, `UPDATE events SET channel_id = $1 WHERE id = $2`, channelID, eventID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to link event channel"})
			return
		}

		// Add organizer as channel admin
		_, err = tx.Exec(ctx, `
			INSERT INTO channel_members (channel_id, user_id, role, joined_at)
			VALUES ($1, $2, 'admin', $3)
		`, channelID, userID, now)

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to add organizer to channel"})
			return
		}
	}

	// Commit transaction
	if err := tx.Commit(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to commit transaction"})
		return
	}

	// Add topic associations (non-critical, after commit)
	for _, topicID := range req.TopicIDs {
		h.db.Pool().Exec(ctx, `
			INSERT INTO event_topics (event_id, topic_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, eventID, topicID)
	}

	response := gin.H{
		"id":      eventID,
		"message": "event created",
	}
	if channelID != "" {
		response["channel_id"] = channelID
	}
	c.JSON(http.StatusCreated, response)
}

// GetEvent returns a single event
func (h *Handler) GetEvent(c *gin.Context) {
	eventID := c.Param("id")
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	var id, organizerID, title, eventType, locationVisibility string
	var description, locationName, locationArea, channelID *string
	var locationRevealAt *time.Time
	var lat, lon float64
	var startsAt time.Time
	var endsAt *time.Time
	var isCancelled bool

	err := h.db.Pool().QueryRow(ctx, `
		SELECT e.id, e.organizer_id, e.title, e.description, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.location_area, e.location_visibility, e.location_reveal_at,
			   e.starts_at, e.ends_at, e.is_cancelled, e.channel_id
		FROM events e
		WHERE e.id = $1
	`, eventID).Scan(&id, &organizerID, &title, &description, &eventType, &lat, &lon,
		&locationName, &locationArea, &locationVisibility, &locationRevealAt,
		&startsAt, &endsAt, &isCancelled, &channelID)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "event not found"})
		return
	}

	// Get RSVP count
	var rsvpCount int
	h.db.Pool().QueryRow(ctx, "SELECT COUNT(*) FROM event_rsvps WHERE event_id = $1 AND status = 'going'", eventID).Scan(&rsvpCount)

	// Check if current user has RSVP'd
	var userRSVP *string
	var hasRSVP bool
	err = h.db.Pool().QueryRow(ctx, "SELECT status FROM event_rsvps WHERE event_id = $1 AND user_id = $2", eventID, userID).Scan(&userRSVP)
	hasRSVP = err == nil && userRSVP != nil

	event := gin.H{
		"id":                  id,
		"organizer_id":        organizerID,
		"title":               title,
		"event_type":          eventType,
		"starts_at":           startsAt,
		"is_cancelled":        isCancelled,
		"rsvp_count":          rsvpCount,
		"location_visibility": locationVisibility,
	}

	// Include channel_id if available
	if channelID != nil {
		event["channel_id"] = *channelID

		// Check if user is a member of the event channel
		var isChannelMember bool
		h.db.Pool().QueryRow(ctx, `
			SELECT EXISTS(SELECT 1 FROM channel_members WHERE channel_id = $1 AND user_id = $2)
		`, *channelID, userID).Scan(&isChannelMember)
		event["is_channel_member"] = isChannelMember
	}

	// Conditionally include exact location
	if shouldRevealLocation(locationVisibility, locationRevealAt, userID, organizerID, hasRSVP) {
		event["location"] = gin.H{"latitude": lat, "longitude": lon}
		if locationName != nil {
			event["location_name"] = *locationName
		}
		event["location_revealed"] = true
	} else {
		event["location_revealed"] = false
		if locationArea != nil {
			event["location_area"] = *locationArea
		}
		if locationVisibility == "timed" && locationRevealAt != nil {
			event["location_reveal_at"] = *locationRevealAt
		}
		if locationVisibility == "rsvp" {
			event["location_hint"] = "RSVP to see exact location"
		}
	}

	if description != nil {
		event["description"] = *description
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
		Title              *string `json:"title"`
		Description        *string `json:"description"`
		LocationName       *string `json:"location_name"`
		LocationArea       *string `json:"location_area"`
		LocationVisibility *string `json:"location_visibility"`
		LocationRevealAt   *int64  `json:"location_reveal_at"`
		StartsAt           *int64  `json:"starts_at"`
		EndsAt             *int64  `json:"ends_at"`
		IsCancelled        *bool   `json:"is_cancelled"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Convert reveal timestamp if provided
	var revealAt *time.Time
	if req.LocationRevealAt != nil {
		t := time.Unix(*req.LocationRevealAt, 0)
		revealAt = &t
	}

	// Build update query
	_, err = h.db.Pool().Exec(ctx, `
		UPDATE events SET
			title = COALESCE($3, title),
			description = COALESCE($4, description),
			location_name = COALESCE($5, location_name),
			location_area = COALESCE($6, location_area),
			location_visibility = COALESCE($7, location_visibility),
			location_reveal_at = COALESCE($8, location_reveal_at),
			is_cancelled = COALESCE($9, is_cancelled),
			updated_at = NOW()
		WHERE id = $1 AND organizer_id = $2
	`, eventID, userID, req.Title, req.Description, req.LocationName, req.LocationArea,
		req.LocationVisibility, revealAt, req.IsCancelled)

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

	// Verify event exists and get visibility info + channel_id
	var exists bool
	var locationVisibility string
	var locationRevealAt *time.Time
	var lat, lon float64
	var locationName, channelID *string

	err := h.db.Pool().QueryRow(ctx, `
		SELECT true, location_visibility, location_reveal_at,
		       ST_Y(location::geometry) as lat, ST_X(location::geometry) as lon, location_name, channel_id
		FROM events WHERE id = $1
	`, eventID).Scan(&exists, &locationVisibility, &locationRevealAt, &lat, &lon, &locationName, &channelID)

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

	response := gin.H{"message": "RSVP recorded", "status": req.Status}

	// If this is a going/interested RSVP, add user to the event channel
	if (req.Status == "going" || req.Status == "interested") && channelID != nil {
		// Add user to channel (ignore if already member)
		_, _ = h.db.Pool().Exec(ctx, `
			INSERT INTO channel_members (channel_id, user_id, role, joined_at)
			VALUES ($1, $2, 'member', NOW())
			ON CONFLICT (channel_id, user_id) DO NOTHING
		`, *channelID, userID)

		response["channel_id"] = *channelID
		response["joined_channel"] = true
	}

	// If this is a going/interested RSVP for an rsvp-only event, reveal the location
	if (req.Status == "going" || req.Status == "interested") && locationVisibility == "rsvp" {
		response["location"] = gin.H{"latitude": lat, "longitude": lon}
		if locationName != nil {
			response["location_name"] = *locationName
		}
		response["location_revealed"] = true
	}

	c.JSON(http.StatusOK, response)
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

// GetNearbyEvents returns events near a location (PUBLIC events only for map display)
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

	// Only return PUBLIC events for map/nearby display
	rows, err := h.db.Pool().Query(ctx, `
		SELECT e.id, e.title, e.event_type,
			   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
			   e.location_name, e.starts_at,
			   ST_Distance(e.location, ST_MakePoint($2, $1)::geography) as distance_meters,
			   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count
		FROM events e
		WHERE e.starts_at > NOW()
		  AND e.is_cancelled = false
		  AND e.location_visibility = 'public'
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

// GetPublicEventsForMap returns all public events with locations for map display
func (h *Handler) GetPublicEventsForMap(c *gin.Context) {
	ctx := c.Request.Context()

	// Parse bounding box if provided
	minLat, _ := strconv.ParseFloat(c.Query("min_lat"), 64)
	maxLat, _ := strconv.ParseFloat(c.Query("max_lat"), 64)
	minLon, _ := strconv.ParseFloat(c.Query("min_lon"), 64)
	maxLon, _ := strconv.ParseFloat(c.Query("max_lon"), 64)

	var rows interface{ Close(); Next() bool; Scan(...interface{}) error }
	var err error

	if minLat != 0 || maxLat != 0 {
		// Query with bounding box
		rows, err = h.db.Pool().Query(ctx, `
			SELECT e.id, e.title, e.event_type,
				   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
				   e.location_name, e.starts_at,
				   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count
			FROM events e
			WHERE e.starts_at > NOW()
			  AND e.is_cancelled = false
			  AND e.location_visibility = 'public'
			  AND ST_Y(e.location::geometry) BETWEEN $1 AND $2
			  AND ST_X(e.location::geometry) BETWEEN $3 AND $4
			ORDER BY e.starts_at ASC
			LIMIT 100
		`, minLat, maxLat, minLon, maxLon)
	} else {
		// Query all upcoming public events
		rows, err = h.db.Pool().Query(ctx, `
			SELECT e.id, e.title, e.event_type,
				   ST_Y(e.location::geometry) as lat, ST_X(e.location::geometry) as lon,
				   e.location_name, e.starts_at,
				   (SELECT COUNT(*) FROM event_rsvps WHERE event_id = e.id AND status = 'going') as rsvp_count
			FROM events e
			WHERE e.starts_at > NOW()
			  AND e.is_cancelled = false
			  AND e.location_visibility = 'public'
			ORDER BY e.starts_at ASC
			LIMIT 100
		`)
	}

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch events"})
		return
	}
	defer rows.Close()

	var events []gin.H
	for rows.Next() {
		var id, title, eventType string
		var lat, lon float64
		var locationName *string
		var startsAt time.Time
		var rsvpCount int

		if err := rows.Scan(&id, &title, &eventType, &lat, &lon, &locationName, &startsAt, &rsvpCount); err != nil {
			continue
		}

		event := gin.H{
			"id":         id,
			"title":      title,
			"event_type": eventType,
			"location":   gin.H{"latitude": lat, "longitude": lon},
			"starts_at":  startsAt,
			"rsvp_count": rsvpCount,
		}

		if locationName != nil {
			event["location_name"] = *locationName
		}

		events = append(events, event)
	}

	c.JSON(http.StatusOK, gin.H{"events": events})
}
