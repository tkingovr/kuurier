package media

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// Handler handles media upload endpoints
type Handler struct {
	cfg   *config.Config
	db    *storage.Postgres
	minio *storage.MinIO
}

// NewHandler creates a new media handler
func NewHandler(cfg *config.Config, db *storage.Postgres, minio *storage.MinIO) *Handler {
	return &Handler{cfg: cfg, db: db, minio: minio}
}

// Upload handles media file uploads
func (h *Handler) Upload(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	// Get the file from form data
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "no file provided"})
		return
	}
	defer file.Close()

	// Validate file size (max 50MB)
	if header.Size > 50*1024*1024 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "file too large (max 50MB)"})
		return
	}

	// Determine media type from content type
	contentType := header.Header.Get("Content-Type")
	var mediaType string

	switch {
	case strings.HasPrefix(contentType, "image/"):
		mediaType = "image"
		// Validate image types
		if !isValidImageType(contentType) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid image type (allowed: jpeg, png, gif, webp)"})
			return
		}
	case strings.HasPrefix(contentType, "video/"):
		mediaType = "video"
		// Validate video types
		if !isValidVideoType(contentType) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid video type (allowed: mp4, webm, mov)"})
			return
		}
	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "unsupported file type"})
		return
	}

	// Generate unique filename
	ext := filepath.Ext(header.Filename)
	if ext == "" {
		ext = getExtensionFromContentType(contentType)
	}
	objectName := fmt.Sprintf("%s/%s/%s%s",
		mediaType,
		time.Now().Format("2006/01/02"),
		uuid.New().String(),
		ext,
	)

	// Upload to MinIO
	url, err := h.minio.UploadFile(c.Request.Context(), objectName, file, header.Size, contentType)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to upload file"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"url":        url,
		"media_type": mediaType,
		"size":       header.Size,
		"filename":   header.Filename,
	})
}

// AttachToPost attaches uploaded media to a post
func (h *Handler) AttachToPost(c *gin.Context) {
	ctx := c.Request.Context()
	userID := c.GetString("user_id")
	postID := c.Param("post_id")

	// Verify post belongs to user
	var authorID string
	err := h.db.Pool().QueryRow(ctx, "SELECT author_id FROM posts WHERE id = $1", postID).Scan(&authorID)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "post not found"})
		return
	}

	if authorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "not authorized to modify this post"})
		return
	}

	var req struct {
		MediaURL  string `json:"media_url" binding:"required"`
		MediaType string `json:"media_type" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request"})
		return
	}

	// Validate media type
	if req.MediaType != "image" && req.MediaType != "video" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "media_type must be 'image' or 'video'"})
		return
	}

	// Insert media record
	var mediaID string
	err = h.db.Pool().QueryRow(ctx, `
		INSERT INTO post_media (post_id, media_url, media_type)
		VALUES ($1, $2, $3)
		RETURNING id
	`, postID, req.MediaURL, req.MediaType).Scan(&mediaID)

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to attach media"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":         mediaID,
		"post_id":    postID,
		"media_url":  req.MediaURL,
		"media_type": req.MediaType,
	})
}

func isValidImageType(contentType string) bool {
	validTypes := []string{
		"image/jpeg",
		"image/png",
		"image/gif",
		"image/webp",
	}
	for _, t := range validTypes {
		if contentType == t {
			return true
		}
	}
	return false
}

func isValidVideoType(contentType string) bool {
	validTypes := []string{
		"video/mp4",
		"video/webm",
		"video/quicktime",
	}
	for _, t := range validTypes {
		if contentType == t {
			return true
		}
	}
	return false
}

func getExtensionFromContentType(contentType string) string {
	switch contentType {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "video/webm":
		return ".webm"
	case "video/quicktime":
		return ".mov"
	default:
		return ""
	}
}
