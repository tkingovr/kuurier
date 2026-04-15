package feed

import (
	"context"
	"log"
	"math"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles feed-related endpoints.
//
// Phase 4 note: news is no longer a separate service. The news bot
// (in the worker process) writes RSS articles to the posts table as
// source_type='mainstream' posts. Both the regular feed and the
// news-only feed (FeedTypeNews) read from posts, so there's only
// one code path for news ingestion.
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new feed handler.
func NewHandler(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{cfg: cfg, db: db, redis: redis}
}

// CreatePostRequest represents a new post
type CreatePostRequest struct {
	Content      string   `json:"content" binding:"required,max=2000"`
	SourceType   string   `json:"source_type" binding:"required,oneof=firsthand aggregated mainstream"`
	Latitude     *float64 `json:"latitude"`
	Longitude    *float64 `json:"longitude"`
	LocationName string   `json:"location_name"`
	Urgency      int      `json:"urgency" binding:"min=1,max=3"`
	TopicIDs     []string `json:"topic_ids"`
	ExpiresAt    *int64   `json:"expires_at"` // Unix timestamp
}

// FeedType represents the type of feed requested.
type FeedType string

const (
	FeedTypeForYou    FeedType = "for_you"
	FeedTypeFollowing FeedType = "following"
	FeedTypeLocal     FeedType = "local"
	FeedTypeCrisis    FeedType = "crisis"
	FeedTypeNews      FeedType = "news"
)

type feedSubscription struct {
	topicID      *string
	latitude     *float64
	longitude    *float64
	radiusMeters *int
	minUrgency   int
}

type postCandidate struct {
	id                string
	authorID          string
	content           string
	sourceType        string
	latitude          *float64
	longitude         *float64
	locationName      *string
	urgency           int
	createdAt         time.Time
	verificationScore int
	authorTrustScore  int
	topicIDs          []string
}

type scoredFeedItem struct {
	score    float64
	itemType string
	post     *postCandidate
	why      []string
}

// GetFeed returns the user's personalized feed
func (h *Handler) GetFeed(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	// Parse and validate pagination
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

	if limit < 1 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	// Apply query timeout to prevent slow queries from blocking
	queryCtx, queryCancel := context.WithTimeout(ctx, 10*time.Second)
	defer queryCancel()

	// Get posts matching user's subscriptions
	rows, err := h.db.Pool().Query(queryCtx, `
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

	posts := make([]gin.H, 0)
	var postIDs []string
	for rows.Next() {
		var id, authorID, content, sourceType string
		var lat, lon *float64
		var locationName *string
		var urgency, verificationScore int
		var createdAt time.Time

		if err := rows.Scan(&id, &authorID, &content, &sourceType, &lat, &lon, &locationName, &urgency, &createdAt, &verificationScore); err != nil {
			log.Printf("feed: scan error: %v", err)
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
		postIDs = append(postIDs, id)
	}

	// Batch-load media for all posts in a single query (eliminates N+1)
	mediaMap := h.getPostMediaBatch(ctx, postIDs)
	for i, post := range posts {
		if media, ok := mediaMap[post["id"].(string)]; ok && len(media) > 0 {
			posts[i]["media"] = media
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"posts":  posts,
		"limit":  limit,
		"offset": offset,
	})
}

// GetFeedV2 returns the ranked, multi-source feed with optional personalization.
func (h *Handler) GetFeedV2(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	feedType := FeedType(c.DefaultQuery("type", string(FeedTypeForYou)))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "30"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	if limit < 1 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	var lat *float64
	var lon *float64
	if q := c.Query("lat"); q != "" {
		if v, err := strconv.ParseFloat(q, 64); err == nil {
			lat = &v
		}
	}
	if q := c.Query("lon"); q != "" {
		if v, err := strconv.ParseFloat(q, 64); err == nil {
			lon = &v
		}
	}

	radiusMeters, _ := strconv.Atoi(c.DefaultQuery("radius_m", "50000"))
	if radiusMeters > 200000 {
		radiusMeters = 200000
	}
	minUrgency, _ := strconv.Atoi(c.DefaultQuery("min_urgency", "0"))

	if feedType == FeedTypeNews {
		h.respondWithNewsFeed(c, limit, offset)
		return
	}

	subscriptions, topicNames, err := h.getUserSubscriptions(ctx, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to load subscriptions"})
		return
	}

	candidates, err := h.fetchFeedCandidates(ctx, 1200)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch candidates"})
		return
	}

	scoredItems := h.rankFeedCandidates(feedType, candidates, subscriptions, topicNames, lat, lon, radiusMeters, minUrgency)

	// News articles enter the feed naturally as posts with
	// source_type='mainstream' (written by the news bot), so no
	// separate live-fetch mix-in here.

	items := h.buildFeedResponseItems(ctx, scoredItems)

	// Apply pagination
	start := offset
	if start > len(items) {
		start = len(items)
	}
	end := start + limit
	if end > len(items) {
		end = len(items)
	}

	paged := items[start:end]
	nextOffset := offset + len(paged)
	if nextOffset >= len(items) {
		nextOffset = -1
	}

	c.JSON(http.StatusOK, gin.H{
		"items":       paged,
		"limit":       limit,
		"offset":      offset,
		"next_offset": nextOffset,
	})
}

// CreatePost creates a new post
func (h *Handler) CreatePost(c *gin.Context) {
	userID := c.GetString("user_id")
	trustScore := c.GetFloat64("trust_score")

	// Require minimum trust to post (invite = 15, one vouch = +10, total = 25)
	if trustScore < 25 {
		c.JSON(http.StatusForbidden, gin.H{
			"error":    "insufficient trust level to post",
			"required": 25,
			"current":  int(trustScore),
			"message":  "Get vouched by one more trusted member to unlock posting",
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

	// Handle expiration
	var expiresAt *time.Time
	if req.ExpiresAt != nil {
		t := time.Unix(*req.ExpiresAt, 0)
		expiresAt = &t
	}

	// Insert post — use ST_MakePoint with parameterized coordinates (no string building)
	var err error
	if req.Latitude != nil && req.Longitude != nil {
		_, err = h.db.Pool().Exec(ctx, `
			INSERT INTO posts (id, author_id, content, source_type, location, location_name, urgency, expires_at)
			VALUES ($1, $2, $3, $4, ST_SetSRID(ST_MakePoint($5, $6)::geography, 4326), $7, $8, $9)
		`, postID, userID, req.Content, req.SourceType, *req.Longitude, *req.Latitude, req.LocationName, req.Urgency, expiresAt)
	} else {
		_, err = h.db.Pool().Exec(ctx, `
			INSERT INTO posts (id, author_id, content, source_type, location_name, urgency, expires_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
		`, postID, userID, req.Content, req.SourceType, req.LocationName, req.Urgency, expiresAt)
	}

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create post"})
		return
	}

	// Insert topic associations (batch insert in a single query for atomicity)
	if len(req.TopicIDs) > 0 {
		for _, topicID := range req.TopicIDs {
			if _, err := h.db.Pool().Exec(ctx, `
				INSERT INTO post_topics (post_id, topic_id) VALUES ($1, $2)
				ON CONFLICT DO NOTHING
			`, postID, topicID); err != nil {
				log.Printf("feed: failed to insert topic %s for post %s: %v", topicID, postID, err)
			}
		}
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

	// Fetch media for this post
	media := h.getPostMedia(ctx, id)
	if len(media) > 0 {
		post["media"] = media
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
			log.Printf("feed: subscription list scan error: %v", err)
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

	var err error
	if req.Latitude != nil && req.Longitude != nil {
		_, err = h.db.Pool().Exec(ctx, `
			INSERT INTO subscriptions (id, user_id, topic_id, location, radius_meters, min_urgency, digest_mode)
			VALUES ($1, $2, $3, ST_SetSRID(ST_MakePoint($4, $5)::geography, 4326), $6, $7, $8)
		`, subID, userID, req.TopicID, *req.Longitude, *req.Latitude, req.RadiusMeters, req.MinUrgency, req.DigestMode)
	} else {
		_, err = h.db.Pool().Exec(ctx, `
			INSERT INTO subscriptions (id, user_id, topic_id, radius_meters, min_urgency, digest_mode)
			VALUES ($1, $2, $3, $4, $5, $6)
		`, subID, userID, req.TopicID, req.RadiusMeters, req.MinUrgency, req.DigestMode)
	}

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

// getPostMedia fetches media attachments for a single post (used for single-post endpoints).
func (h *Handler) getPostMedia(ctx context.Context, postID string) []gin.H {
	m := h.getPostMediaBatch(ctx, []string{postID})
	return m[postID]
}

// getPostMediaBatch fetches media attachments for multiple posts in a single query.
// Returns a map of postID -> media items. This eliminates the N+1 query problem.
func (h *Handler) getPostMediaBatch(ctx context.Context, postIDs []string) map[string][]gin.H {
	result := make(map[string][]gin.H)
	if len(postIDs) == 0 {
		return result
	}

	rows, err := h.db.Pool().Query(ctx, `
		SELECT post_id, id, media_url, media_type, created_at
		FROM post_media
		WHERE post_id = ANY($1)
		ORDER BY created_at ASC
	`, postIDs)

	if err != nil {
		log.Printf("feed: batch media query error: %v", err)
		return result
	}
	defer rows.Close()

	for rows.Next() {
		var postID, id, mediaURL, mediaType string
		var createdAt time.Time

		if err := rows.Scan(&postID, &id, &mediaURL, &mediaType, &createdAt); err != nil {
			log.Printf("feed: media scan error: %v", err)
			continue
		}

		result[postID] = append(result[postID], gin.H{
			"id":         id,
			"url":        mediaURL,
			"type":       mediaType,
			"created_at": createdAt,
		})
	}

	return result
}

// respondWithNewsFeed returns bot-posted news articles (source_type
// = 'mainstream') from the posts table, sorted by recency.
//
// Phase 4 note: this used to live-fetch RSS feeds at request time via
// an in-process cache. That path is gone — the news bot (now in the
// worker process) writes articles to the posts table, and this
// handler is a simple paginated query against that table.
func (h *Handler) respondWithNewsFeed(c *gin.Context, limit, offset int) {
	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx, `
		SELECT p.id, p.author_id, p.content, p.source_type,
		       ST_Y(p.location::geometry) as lat,
		       ST_X(p.location::geometry) as lon,
		       p.location_name, p.urgency, p.created_at, p.verification_score,
		       COALESCE(u.trust_score, 0) as trust_score
		FROM posts p
		LEFT JOIN users u ON u.id = p.author_id
		WHERE p.source_type = 'mainstream'
		  AND p.is_flagged = false
		  AND p.created_at > NOW() - INTERVAL '7 days'
		ORDER BY p.created_at DESC
		LIMIT $1 OFFSET $2
	`, limit, offset)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch news"})
		return
	}
	defer rows.Close()

	scored := make([]scoredFeedItem, 0, limit)
	for rows.Next() {
		var post postCandidate
		if err := rows.Scan(
			&post.id, &post.authorID, &post.content, &post.sourceType,
			&post.latitude, &post.longitude,
			&post.locationName, &post.urgency, &post.createdAt, &post.verificationScore,
			&post.authorTrustScore,
		); err != nil {
			continue
		}
		scored = append(scored, scoredFeedItem{
			score:    recencyScore(post.createdAt),
			itemType: "post",
			post:     &post,
			why:      []string{"News"},
		})
	}

	items := h.buildFeedResponseItems(ctx, scored)

	nextOffset := offset + len(items)
	// If we got fewer than the limit, we're at the end.
	if len(items) < limit {
		nextOffset = -1
	}

	c.JSON(http.StatusOK, gin.H{
		"items":       items,
		"limit":       limit,
		"offset":      offset,
		"next_offset": nextOffset,
	})
}

func (h *Handler) getUserSubscriptions(ctx context.Context, userID string) ([]feedSubscription, map[string]string, error) {
	rows, err := h.db.Pool().Query(ctx, `
		SELECT s.topic_id,
			   ST_Y(s.location::geometry) as lat,
			   ST_X(s.location::geometry) as lon,
			   s.radius_meters,
			   s.min_urgency
		FROM subscriptions s
		WHERE s.user_id = $1 AND s.is_active = true
	`, userID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	var subs []feedSubscription
	for rows.Next() {
		var topicID *string
		var lat, lon *float64
		var radius *int
		var minUrgency int
		if err := rows.Scan(&topicID, &lat, &lon, &radius, &minUrgency); err != nil {
			log.Printf("feed: subscription scan error: %v", err)
			continue
		}
		subs = append(subs, feedSubscription{
			topicID:      topicID,
			latitude:     lat,
			longitude:    lon,
			radiusMeters: radius,
			minUrgency:   minUrgency,
		})
	}

	topicRows, err := h.db.Pool().Query(ctx, `SELECT id, name FROM topics`)
	if err != nil {
		return subs, nil, err
	}
	defer topicRows.Close()

	topicNames := make(map[string]string)
	for topicRows.Next() {
		var id, name string
		if err := topicRows.Scan(&id, &name); err == nil {
			topicNames[id] = name
		}
	}

	return subs, topicNames, nil
}

func (h *Handler) fetchFeedCandidates(ctx context.Context, limit int) ([]postCandidate, error) {
	rows, err := h.db.Pool().Query(ctx, `
		SELECT p.id, p.author_id, p.content, p.source_type,
			   ST_Y(p.location::geometry) as lat,
			   ST_X(p.location::geometry) as lon,
			   p.location_name, p.urgency, p.created_at, p.verification_score,
			   u.trust_score,
			   ARRAY_REMOVE(ARRAY_AGG(DISTINCT pt.topic_id::text), NULL) AS topic_ids
		FROM posts p
		JOIN users u ON u.id = p.author_id
		LEFT JOIN post_topics pt ON pt.post_id = p.id
		WHERE p.is_flagged = false
		  AND (p.expires_at IS NULL OR p.expires_at > NOW())
		  AND p.created_at > NOW() - INTERVAL '14 days'
		GROUP BY p.id, p.author_id, p.content, p.source_type, p.location, p.location_name,
				 p.urgency, p.created_at, p.verification_score, u.trust_score
		ORDER BY p.created_at DESC
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var posts []postCandidate
	for rows.Next() {
		var post postCandidate
		var topicIDs []string
		if err := rows.Scan(
			&post.id,
			&post.authorID,
			&post.content,
			&post.sourceType,
			&post.latitude,
			&post.longitude,
			&post.locationName,
			&post.urgency,
			&post.createdAt,
			&post.verificationScore,
			&post.authorTrustScore,
			&topicIDs,
		); err != nil {
			log.Printf("feed: candidate scan error: %v", err)
			continue
		}
		post.topicIDs = topicIDs
		posts = append(posts, post)
	}

	return posts, nil
}

func (h *Handler) rankFeedCandidates(
	feedType FeedType,
	candidates []postCandidate,
	subscriptions []feedSubscription,
	topicNames map[string]string,
	userLat, userLon *float64,
	radiusMeters int,
	minUrgency int,
) []scoredFeedItem {
	subscriptionTopics := make(map[string]int)
	var locationSubs []feedSubscription
	for _, sub := range subscriptions {
		if sub.topicID != nil {
			subscriptionTopics[*sub.topicID] = sub.minUrgency
		}
		if sub.latitude != nil && sub.longitude != nil {
			locationSubs = append(locationSubs, sub)
		}
	}

	scored := make([]scoredFeedItem, 0, len(candidates))
	for _, post := range candidates {
		if minUrgency > 0 && post.urgency < minUrgency {
			continue
		}

		topicMatch, matchedTopic := postMatchesTopics(post.topicIDs, subscriptionTopics, post.urgency)
		locationMatch := postMatchesLocation(post, locationSubs)

		distance := -1.0
		if userLat != nil && userLon != nil && post.latitude != nil && post.longitude != nil {
			distance = distanceMeters(*userLat, *userLon, *post.latitude, *post.longitude)
		}

		switch feedType {
		case FeedTypeFollowing:
			if !topicMatch && !locationMatch {
				continue
			}
		case FeedTypeLocal:
			if userLat != nil && userLon != nil && distance >= 0 {
				if distance > float64(radiusMeters) {
					continue
				}
			} else if !locationMatch {
				continue
			}
		case FeedTypeCrisis:
			if post.urgency < 2 || time.Since(post.createdAt) > 72*time.Hour {
				continue
			}
			if distance > 1000_000 && post.urgency < 3 {
				continue
			}
		}

		recency := recencyScore(post.createdAt)
		interest := 0.0
		if topicMatch {
			interest = 1.0
		}
		proximity := 0.0
		if distance >= 0 && radiusMeters > 0 {
			proximity = 1.0 - math.Min(distance/float64(radiusMeters), 1.0)
		}
		urgency := (float64(post.urgency) - 1.0) / 2.0
		trust := confidenceScore(post)
		negative := 0.0
		if post.verificationScore < 0 {
			negative = math.Min(float64(-post.verificationScore)/10.0, 1.0)
		}

		score := 0.0
		switch feedType {
		case FeedTypeCrisis:
			score = 0.45*urgency + 0.35*recency + 0.20*trust
		case FeedTypeLocal:
			score = 0.40*proximity + 0.25*recency + 0.20*urgency + 0.15*trust
		case FeedTypeFollowing:
			score = 0.40*recency + 0.30*interest + 0.15*urgency + 0.15*trust
		default:
			score = 0.30*recency + 0.25*interest + 0.20*proximity + 0.15*urgency + 0.10*trust - 0.10*negative
		}

		// Boost news posts so they aren't buried behind community posts
		if post.sourceType == "mainstream" {
			score += 0.15 * recency
		}

		why := buildWhyList(feedType, topicMatch, matchedTopic, topicNames, proximity, urgency, trust)

		scored = append(scored, scoredFeedItem{
			score:    score,
			itemType: "post",
			post:     &post,
			why:      why,
		})
	}

	sort.Slice(scored, func(i, j int) bool { return scored[i].score > scored[j].score })

	// Basic author diversity: avoid long streaks by the same author.
	// News bot posts (source_type=mainstream) are exempt — they share one author
	// but represent different sources and should not be deduplicated.
	var diversified []scoredFeedItem
	var lastAuthor string
	streak := 0
	for _, item := range scored {
		if item.post == nil {
			diversified = append(diversified, item)
			continue
		}
		if item.post.sourceType == "mainstream" {
			diversified = append(diversified, item)
			continue
		}
		if item.post.authorID == lastAuthor {
			if streak >= 2 {
				continue
			}
			streak++
		} else {
			lastAuthor = item.post.authorID
			streak = 1
		}
		diversified = append(diversified, item)
	}

	return diversified
}

func (h *Handler) buildFeedResponseItems(ctx context.Context, items []scoredFeedItem) []gin.H {
	// Collect all post IDs for batch media loading
	var postIDs []string
	for _, item := range items {
		if item.post != nil {
			postIDs = append(postIDs, item.post.id)
		}
	}
	mediaMap := h.getPostMediaBatch(ctx, postIDs)

	result := make([]gin.H, 0, len(items))
	for _, item := range items {
		// All feed items are posts now. News articles appear as posts
		// with source_type='mainstream' after Phase 4.
		if item.post == nil {
			continue
		}
		{
			post := item.post
			postJSON := gin.H{
				"id":                 post.id,
				"author_id":          post.authorID,
				"content":            post.content,
				"source_type":        post.sourceType,
				"urgency":            post.urgency,
				"created_at":         post.createdAt,
				"verification_score": post.verificationScore,
			}

			if post.latitude != nil && post.longitude != nil {
				postJSON["location"] = gin.H{"latitude": *post.latitude, "longitude": *post.longitude}
			}
			if post.locationName != nil {
				postJSON["location_name"] = *post.locationName
			}

			if media, ok := mediaMap[post.id]; ok && len(media) > 0 {
				postJSON["media"] = media
			}

			result = append(result, gin.H{
				"id":   "post-" + post.id,
				"type": "post",
				"post": postJSON,
				"why":  item.why,
			})
		}
	}
	return result
}

func recencyScore(createdAt time.Time) float64 {
	ageHours := time.Since(createdAt).Hours()
	halfLife := 8.0
	return math.Exp(-math.Ln2 * ageHours / halfLife)
}

func confidenceScore(post postCandidate) float64 {
	trustNorm := math.Min(float64(post.authorTrustScore)/100.0, 1.0)
	verificationNorm := (math.Min(math.Max(float64(post.verificationScore), -5.0), 10.0) + 5.0) / 15.0
	sourceWeight := 0.6
	switch post.sourceType {
	case "firsthand":
		sourceWeight = 1.0
	case "aggregated":
		sourceWeight = 0.7
	case "mainstream":
		sourceWeight = 0.6
	}
	return 0.5*trustNorm + 0.3*verificationNorm + 0.2*sourceWeight
}

func distanceMeters(lat1, lon1, lat2, lon2 float64) float64 {
	const earthRadius = 6371000.0
	lat1Rad := lat1 * math.Pi / 180.0
	lat2Rad := lat2 * math.Pi / 180.0
	deltaLat := (lat2 - lat1) * math.Pi / 180.0
	deltaLon := (lon2 - lon1) * math.Pi / 180.0

	a := math.Sin(deltaLat/2)*math.Sin(deltaLat/2) +
		math.Cos(lat1Rad)*math.Cos(lat2Rad)*
			math.Sin(deltaLon/2)*math.Sin(deltaLon/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return earthRadius * c
}

func postMatchesTopics(postTopicIDs []string, subTopics map[string]int, urgency int) (bool, *string) {
	for _, topicID := range postTopicIDs {
		if minUrgency, ok := subTopics[topicID]; ok && urgency >= minUrgency {
			return true, &topicID
		}
	}
	return false, nil
}

func postMatchesLocation(post postCandidate, subs []feedSubscription) bool {
	if post.latitude == nil || post.longitude == nil {
		return false
	}
	for _, sub := range subs {
		if sub.latitude == nil || sub.longitude == nil || sub.radiusMeters == nil {
			continue
		}
		distance := distanceMeters(*sub.latitude, *sub.longitude, *post.latitude, *post.longitude)
		if distance <= float64(*sub.radiusMeters) && post.urgency >= sub.minUrgency {
			return true
		}
	}
	return false
}

func buildWhyList(feedType FeedType, topicMatch bool, matchedTopic *string, topicNames map[string]string, proximity, urgency, trust float64) []string {
	var why []string

	if feedType == FeedTypeCrisis {
		why = append(why, "Crisis alert")
	}

	if topicMatch && matchedTopic != nil {
		if name, ok := topicNames[*matchedTopic]; ok {
			why = append(why, "Topic: "+name)
		}
	}
	if proximity >= 0.6 {
		why = append(why, "Near you")
	}
	if urgency >= 0.8 {
		why = append(why, "High urgency")
	}
	if trust >= 0.7 {
		why = append(why, "Trusted source")
	}

	if len(why) > 3 {
		why = why[:3]
	}
	return why
}
