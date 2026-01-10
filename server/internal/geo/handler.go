package geo

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles geospatial/map endpoints
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new geo handler
func NewHandler(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{cfg: cfg, db: db, redis: redis}
}

// GetHeatmap returns aggregated activity data for the world map
func (h *Handler) GetHeatmap(c *gin.Context) {
	ctx := c.Request.Context()

	// Parse bounding box (for viewport)
	minLat, _ := strconv.ParseFloat(c.Query("min_lat"), 64)
	maxLat, _ := strconv.ParseFloat(c.Query("max_lat"), 64)
	minLon, _ := strconv.ParseFloat(c.Query("min_lon"), 64)
	maxLon, _ := strconv.ParseFloat(c.Query("max_lon"), 64)

	// Default to world view
	if minLat == 0 && maxLat == 0 {
		minLat, maxLat = -90, 90
		minLon, maxLon = -180, 180
	}

	// Grid size for aggregation (degrees)
	gridSize := c.DefaultQuery("grid_size", "1") // 1 degree cells by default

	// Query aggregated post counts per grid cell
	rows, err := h.db.Pool().Query(ctx, `
		WITH grid AS (
			SELECT
				FLOOR(ST_Y(location::geometry) / $5) * $5 as lat_cell,
				FLOOR(ST_X(location::geometry) / $5) * $5 as lon_cell,
				COUNT(*) as post_count,
				MAX(urgency) as max_urgency,
				MAX(created_at) as latest_activity
			FROM posts
			WHERE location IS NOT NULL
			  AND is_flagged = false
			  AND (expires_at IS NULL OR expires_at > NOW())
			  AND ST_Y(location::geometry) BETWEEN $1 AND $2
			  AND ST_X(location::geometry) BETWEEN $3 AND $4
			  AND created_at > NOW() - INTERVAL '7 days'
			GROUP BY lat_cell, lon_cell
		)
		SELECT lat_cell, lon_cell, post_count, max_urgency
		FROM grid
		WHERE post_count > 0
		ORDER BY post_count DESC
		LIMIT 500
	`, minLat, maxLat, minLon, maxLon, gridSize)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch heatmap data"})
		return
	}
	defer rows.Close()

	var cells []gin.H
	for rows.Next() {
		var latCell, lonCell float64
		var postCount, maxUrgency int

		if err := rows.Scan(&latCell, &lonCell, &postCount, &maxUrgency); err != nil {
			continue
		}

		// Determine heat level based on activity
		heatLevel := "low"
		if postCount > 10 {
			heatLevel = "medium"
		}
		if postCount > 50 || maxUrgency == 3 {
			heatLevel = "high"
		}

		cells = append(cells, gin.H{
			"latitude":    latCell,
			"longitude":   lonCell,
			"count":       postCount,
			"max_urgency": maxUrgency,
			"heat_level":  heatLevel,
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"cells":     cells,
		"grid_size": gridSize,
	})
}

// GetClusters returns clustered posts for map display
func (h *Handler) GetClusters(c *gin.Context) {
	ctx := c.Request.Context()

	// Parse bounding box
	minLat, _ := strconv.ParseFloat(c.Query("min_lat"), 64)
	maxLat, _ := strconv.ParseFloat(c.Query("max_lat"), 64)
	minLon, _ := strconv.ParseFloat(c.Query("min_lon"), 64)
	maxLon, _ := strconv.ParseFloat(c.Query("max_lon"), 64)

	// Zoom level affects clustering
	zoom, _ := strconv.Atoi(c.DefaultQuery("zoom", "5"))

	// Calculate cluster radius based on zoom (in meters)
	clusterRadius := 100000 / (zoom + 1) // Rough approximation

	// For high zoom levels, return individual posts
	if zoom >= 12 {
		rows, err := h.db.Pool().Query(ctx, `
			SELECT p.id, p.content, p.source_type, p.urgency,
				   ST_Y(p.location::geometry) as lat,
				   ST_X(p.location::geometry) as lon,
				   p.created_at
			FROM posts p
			WHERE p.location IS NOT NULL
			  AND p.is_flagged = false
			  AND ST_Y(p.location::geometry) BETWEEN $1 AND $2
			  AND ST_X(p.location::geometry) BETWEEN $3 AND $4
			  AND (p.expires_at IS NULL OR p.expires_at > NOW())
			ORDER BY p.created_at DESC
			LIMIT 100
		`, minLat, maxLat, minLon, maxLon)

		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch posts"})
			return
		}
		defer rows.Close()

		var posts []gin.H
		for rows.Next() {
			var id, content, sourceType string
			var urgency int
			var lat, lon float64
			var createdAt interface{}

			if err := rows.Scan(&id, &content, &sourceType, &urgency, &lat, &lon, &createdAt); err != nil {
				continue
			}

			posts = append(posts, gin.H{
				"type":        "post",
				"id":          id,
				"content":     content,
				"source_type": sourceType,
				"urgency":     urgency,
				"latitude":    lat,
				"longitude":   lon,
				"created_at":  createdAt,
			})
		}

		c.JSON(http.StatusOK, gin.H{"markers": posts, "clustered": false})
		return
	}

	// Return clusters for lower zoom levels
	rows, err := h.db.Pool().Query(ctx, `
		WITH clustered AS (
			SELECT
				ST_ClusterDBSCAN(location::geometry, eps := $5, minpoints := 1) OVER () AS cluster_id,
				location,
				urgency
			FROM posts
			WHERE location IS NOT NULL
			  AND is_flagged = false
			  AND ST_Y(location::geometry) BETWEEN $1 AND $2
			  AND ST_X(location::geometry) BETWEEN $3 AND $4
			  AND (expires_at IS NULL OR expires_at > NOW())
			  AND created_at > NOW() - INTERVAL '7 days'
		)
		SELECT
			cluster_id,
			ST_Y(ST_Centroid(ST_Collect(location))) as lat,
			ST_X(ST_Centroid(ST_Collect(location))) as lon,
			COUNT(*) as count,
			MAX(urgency) as max_urgency
		FROM clustered
		GROUP BY cluster_id
		ORDER BY count DESC
		LIMIT 200
	`, minLat, maxLat, minLon, maxLon, float64(clusterRadius)/111000) // Convert meters to degrees roughly

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch clusters"})
		return
	}
	defer rows.Close()

	var clusters []gin.H
	for rows.Next() {
		var clusterID *int
		var lat, lon float64
		var count, maxUrgency int

		if err := rows.Scan(&clusterID, &lat, &lon, &count, &maxUrgency); err != nil {
			continue
		}

		clusters = append(clusters, gin.H{
			"type":        "cluster",
			"latitude":    lat,
			"longitude":   lon,
			"count":       count,
			"max_urgency": maxUrgency,
		})
	}

	c.JSON(http.StatusOK, gin.H{"markers": clusters, "clustered": true})
}

// GetNearby returns posts near a specific location
func (h *Handler) GetNearby(c *gin.Context) {
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

	radiusMeters, _ := strconv.Atoi(c.DefaultQuery("radius", "5000"))
	if radiusMeters > 50000 {
		radiusMeters = 50000 // Max 50km
	}

	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	if limit > 100 {
		limit = 100
	}

	rows, err := h.db.Pool().Query(ctx, `
		SELECT p.id, p.content, p.source_type, p.urgency,
			   ST_Y(p.location::geometry) as lat,
			   ST_X(p.location::geometry) as lon,
			   p.location_name,
			   ST_Distance(p.location, ST_MakePoint($2, $1)::geography) as distance_meters,
			   p.created_at
		FROM posts p
		WHERE p.location IS NOT NULL
		  AND p.is_flagged = false
		  AND (p.expires_at IS NULL OR p.expires_at > NOW())
		  AND ST_DWithin(p.location, ST_MakePoint($2, $1)::geography, $3)
		ORDER BY distance_meters ASC
		LIMIT $4
	`, lat, lon, radiusMeters, limit)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch nearby posts"})
		return
	}
	defer rows.Close()

	var posts []gin.H
	for rows.Next() {
		var id, content, sourceType string
		var urgency int
		var postLat, postLon, distance float64
		var locationName *string
		var createdAt interface{}

		if err := rows.Scan(&id, &content, &sourceType, &urgency, &postLat, &postLon, &locationName, &distance, &createdAt); err != nil {
			continue
		}

		post := gin.H{
			"id":              id,
			"content":         content,
			"source_type":     sourceType,
			"urgency":         urgency,
			"latitude":        postLat,
			"longitude":       postLon,
			"distance_meters": int(distance),
			"created_at":      createdAt,
		}

		if locationName != nil {
			post["location_name"] = *locationName
		}

		posts = append(posts, post)
	}

	c.JSON(http.StatusOK, gin.H{
		"posts":  posts,
		"center": gin.H{"latitude": lat, "longitude": lon},
		"radius": radiusMeters,
	})
}
