package feed

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles feed-related endpoints
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new feed handler
func NewHandler(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{cfg: cfg, db: db, redis: redis}
}

// CreatePostRequest represents a new post
type CreatePostRequest struct {
	Content      string    `json:"content" binding:"required,max=2000"`
	SourceType   string    `json:"source_type" binding:"required,oneof=firsthand aggregated mainstream"`
	Latitude     *float64  `json:"latitude"`
	Longitude    *float64  `json:"longitude"`
	LocationName string    `json:"location_name"`
	Urgency      int       `json:"urgency" binding:"min=1,max=3"`
	TopicIDs     []string  `json:"topic_ids"`
	ExpiresAt    *int64    `json:"expires_at"` // Unix timestamp
}

// GetFeed returns the user's personalized feed
func (h *Handler) GetFeed(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	// Parse pagination
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

	if limit > 100 {
		limit = 100
	}

	// Get posts matching user's subscriptions
	rows, err := h.db.Pool().Query(ctx, `
		SELECT DISTINCT p.id, p.author_id, p.content, p.source_type,
			   ST_Y(p.location::geometry) as lat, ST_X(p.location::geometry) as lon,
			   p.location_name, p.urgency, p.created_at, p.verification_score
		FROM posts p
		LEFT JOIN post_topics pt ON p.id = pt.post_id
		LEFT JOIN subscriptions s ON s.user_id = $1 AND s.is_active = true
		WHERE p.is_flagged = false
		  AND (p.expires_at IS NULL OR p.expires_at > NOW())
		  AND (
			  -- Match by topic
			  (s.topic_id IS NOT NULL AND pt.topic_id = s.topic_id AND p.urgency >= s.min_urgency)
			  OR
			  -- Match by location
			  (s.location IS NOT NULL AND ST_DWithin(p.location, s.location, s.radius_meters) AND p.urgency >= s.min_urgency)
			  OR
			  -- If no subscriptions, show recent posts
			  NOT EXISTS (SELECT 1 FROM subscriptions WHERE user_id = $1 AND is_active = true)
		  )
		ORDER BY p.created_at DESC
		LIMIT $2 OFFSET $3
	`, userID, limit, offset)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch feed"})
		return
	}
	defer rows.Close()

	var posts []gin.H
	for rows.Next() {
		var id, authorID, content, sourceType string
		var lat, lon *float64
		var locationName *string
		var urgency, verificationScore int
		var createdAt time.Time

		if err := rows.Scan(&id, &authorID, &content, &sourceType, &lat, &lon, &locationName, &urgency, &createdAt, &verificationScore); err != nil {
			continue
		}

		post := gin.H{
			"id":                 id,
			"author_id":          authorID,
			"content":            content,
			"source_type":        sourceType,
			"urgency":            urgency,
			"created_at":         createdAt,
			"verification_score": verificationScore,
		}

		if lat != nil && lon != nil {
			post["location"] = gin.H{"latitude": *lat, "longitude": *lon}
		}
		if locationName != nil {
			post["location_name"] = *locationName
		}

		posts = append(posts, post)
	}

	c.JSON(http.StatusOK, gin.H{
		"posts":  posts,
		"limit":  limit,
		"offset": offset,
	})
}

// CreatePost creates a new post
func (h *Handler) CreatePost(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := c.GetFloat64("trust_score")

	// Require minimum trust to post
	if trustScore < 30 {
		c.JSON(http.StatusForbidden, gin.H{
			"error":    "insufficient trust level to post",
			"required": 30,
			"current":  int(trustScore),
		})
		return
	}

	var req CreatePostRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ctx := c.Request.Context()
	postID := uuid.New().String()

	// Default urgency
	if req.Urgency == 0 {
		req.Urgency = 1
	}

	// Build location point if provided
	var locationSQL interface{}
	if req.Latitude != nil && req.Longitude != nil {
		locationSQL = "POINT(" + strconv.FormatFloat(*req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(*req.Latitude, 'f', 6, 64) + ")"
	}

	// Handle expiration
	var expiresAt *time.Time
	if req.ExpiresAt != nil {
		t := time.Unix(*req.ExpiresAt, 0)
		expiresAt = &t
	}

	// Insert post
	_, err := h.db.Pool().Exec(ctx, `
		INSERT INTO posts (id, author_id, content, source_type, location, location_name, urgency, expires_at)
		VALUES ($1, $2, $3, $4, ST_GeogFromText($5), $6, $7, $8)
	`, postID, userID, req.Content, req.SourceType, locationSQL, req.LocationName, req.Urgency, expiresAt)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create post"})
		return
	}

	// Insert topic associations
	for _, topicID := range req.TopicIDs {
		h.db.Pool().Exec(ctx, `
			INSERT INTO post_topics (post_id, topic_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, postID, topicID)
	}

	c.JSON(http.StatusCreated, gin.H{
		"id":         postID,
		"message":    "post created",
		"created_at": time.Now().UTC(),
	})
}

// GetPost returns a single post by ID
func (h *Handler) GetPost(c *gin.Context) {
	postID := c.Param("id")
	ctx := c.Request.Context()

	var id, authorID, content, sourceType string
	var lat, lon *float64
	var locationName *string
	var urgency, verificationScore int
	var createdAt time.Time

	err := h.db.Pool().QueryRow(ctx, `
		SELECT p.id, p.author_id, p.content, p.source_type,
			   ST_Y(p.location::geometry), ST_X(p.location::geometry),
			   p.location_name, p.urgency, p.created_at, p.verification_score
		FROM posts p
		WHERE p.id = $1 AND p.is_flagged = false
	`, postID).Scan(&id, &authorID, &content, &sourceType, &lat, &lon, &locationName, &urgency, &createdAt, &verificationScore)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "post not found"})
		return
	}

	post := gin.H{
		"id":                 id,
		"author_id":          authorID,
		"content":            content,
		"source_type":        sourceType,
		"urgency":            urgency,
		"created_at":         createdAt,
		"verification_score": verificationScore,
	}

	if lat != nil && lon != nil {
		post["location"] = gin.H{"latitude": *lat, "longitude": *lon}
	}
	if locationName != nil {
		post["location_name"] = *locationName
	}

	c.JSON(http.StatusOK, post)
}

// DeletePost deletes a post (only by author)
func (h *Handler) DeletePost(c *gin.Context) {
	userID := c.GetString("user_id")
	postID := c.Param("id")
	ctx := c.Request.Context()

	result, err := h.db.Pool().Exec(ctx,
		"DELETE FROM posts WHERE id = $1 AND author_id = $2",
		postID, userID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete post"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "post not found or unauthorized"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "post deleted"})
}

// VerifyPost adds a verification vote to a post
func (h *Handler) VerifyPost(c *gin.Context) {
	postID := c.Param("id")
	ctx := c.Request.Context()

	_, err := h.db.Pool().Exec(ctx,
		"UPDATE posts SET verification_score = verification_score + 1 WHERE id = $1",
		postID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to verify post"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "verification recorded"})
}

// FlagPost flags a post for review
func (h *Handler) FlagPost(c *gin.Context) {
	postID := c.Param("id")
	ctx := c.Request.Context()

	// Decrement verification score; if it goes too negative, flag the post
	_, err := h.db.Pool().Exec(ctx, `
		UPDATE posts
		SET verification_score = verification_score - 1,
			is_flagged = CASE WHEN verification_score - 1 < -5 THEN true ELSE is_flagged END
		WHERE id = $1
	`, postID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to flag post"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "flag recorded"})
}

// GetTopics returns all available topics
func (h *Handler) GetTopics(c *gin.Context) {
	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx, "SELECT id, slug, name, icon FROM topics ORDER BY name")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch topics"})
		return
	}
	defer rows.Close()

	var topics []gin.H
	for rows.Next() {
		var id, slug, name string
		var icon *string
		if err := rows.Scan(&id, &slug, &name, &icon); err == nil {
			topic := gin.H{"id": id, "slug": slug, "name": name}
			if icon != nil {
				topic["icon"] = *icon
			}
			topics = append(topics, topic)
		}
	}

	c.JSON(http.StatusOK, gin.H{"topics": topics})
}

// GetSubscriptions returns user's subscriptions
func (h *Handler) GetSubscriptions(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx, `
		SELECT s.id, s.topic_id, t.name, t.slug,
			   ST_Y(s.location::geometry), ST_X(s.location::geometry),
			   s.radius_meters, s.min_urgency, s.digest_mode, s.is_active
		FROM subscriptions s
		LEFT JOIN topics t ON s.topic_id = t.id
		WHERE s.user_id = $1
		ORDER BY s.created_at DESC
	`, userID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch subscriptions"})
		return
	}
	defer rows.Close()

	var subscriptions []gin.H
	for rows.Next() {
		var id string
		var topicID, topicName, topicSlug *string
		var lat, lon *float64
		var radiusMeters *int
		var minUrgency int
		var digestMode string
		var isActive bool

		if err := rows.Scan(&id, &topicID, &topicName, &topicSlug, &lat, &lon, &radiusMeters, &minUrgency, &digestMode, &isActive); err != nil {
			continue
		}

		sub := gin.H{
			"id":          id,
			"min_urgency": minUrgency,
			"digest_mode": digestMode,
			"is_active":   isActive,
		}

		if topicID != nil {
			sub["topic"] = gin.H{"id": *topicID, "name": *topicName, "slug": *topicSlug}
		}
		if lat != nil && lon != nil {
			sub["location"] = gin.H{"latitude": *lat, "longitude": *lon}
			sub["radius_meters"] = radiusMeters
		}

		subscriptions = append(subscriptions, sub)
	}

	c.JSON(http.StatusOK, gin.H{"subscriptions": subscriptions})
}

// CreateSubscriptionRequest represents a new subscription
type CreateSubscriptionRequest struct {
	TopicID      *string  `json:"topic_id"`
	Latitude     *float64 `json:"latitude"`
	Longitude    *float64 `json:"longitude"`
	RadiusMeters *int     `json:"radius_meters"`
	MinUrgency   int      `json:"min_urgency" binding:"min=1,max=3"`
	DigestMode   string   `json:"digest_mode" binding:"oneof=realtime daily weekly"`
}

// CreateSubscription creates a new subscription
func (h *Handler) CreateSubscription(c *gin.Context) {
	userID := c.GetString("user_id")

	var req CreateSubscriptionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Must have either topic or location
	if req.TopicID == nil && (req.Latitude == nil || req.Longitude == nil) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "must specify topic_id or location"})
		return
	}

	ctx := c.Request.Context()
	subID := uuid.New().String()

	// Default values
	if req.MinUrgency == 0 {
		req.MinUrgency = 1
	}
	if req.DigestMode == "" {
		req.DigestMode = "realtime"
	}

	var locationSQL interface{}
	if req.Latitude != nil && req.Longitude != nil {
		locationSQL = "POINT(" + strconv.FormatFloat(*req.Longitude, 'f', 6, 64) + " " + strconv.FormatFloat(*req.Latitude, 'f', 6, 64) + ")"
	}

	_, err := h.db.Pool().Exec(ctx, `
		INSERT INTO subscriptions (id, user_id, topic_id, location, radius_meters, min_urgency, digest_mode)
		VALUES ($1, $2, $3, ST_GeogFromText($4), $5, $6, $7)
	`, subID, userID, req.TopicID, locationSQL, req.RadiusMeters, req.MinUrgency, req.DigestMode)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create subscription"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"id": subID, "message": "subscription created"})
}

// UpdateSubscription updates an existing subscription
func (h *Handler) UpdateSubscription(c *gin.Context) {
	userID := c.GetString("user_id")
	subID := c.Param("id")

	var req struct {
		MinUrgency *int    `json:"min_urgency"`
		DigestMode *string `json:"digest_mode"`
		IsActive   *bool   `json:"is_active"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ctx := c.Request.Context()

	// Build dynamic update
	updates := make(map[string]interface{})
	if req.MinUrgency != nil {
		updates["min_urgency"] = *req.MinUrgency
	}
	if req.DigestMode != nil {
		updates["digest_mode"] = *req.DigestMode
	}
	if req.IsActive != nil {
		updates["is_active"] = *req.IsActive
	}

	if len(updates) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "no updates provided"})
		return
	}

	// Simple update (in production, use a query builder)
	_, err := h.db.Pool().Exec(ctx, `
		UPDATE subscriptions
		SET min_urgency = COALESCE($3, min_urgency),
			digest_mode = COALESCE($4, digest_mode),
			is_active = COALESCE($5, is_active)
		WHERE id = $1 AND user_id = $2
	`, subID, userID, req.MinUrgency, req.DigestMode, req.IsActive)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update subscription"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "subscription updated"})
}

// DeleteSubscription deletes a subscription
func (h *Handler) DeleteSubscription(c *gin.Context) {
	userID := c.GetString("user_id")
	subID := c.Param("id")
	ctx := c.Request.Context()

	result, err := h.db.Pool().Exec(ctx,
		"DELETE FROM subscriptions WHERE id = $1 AND user_id = $2",
		subID, userID,
	)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete subscription"})
		return
	}

	if result.RowsAffected() == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "subscription not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "subscription deleted"})
}
