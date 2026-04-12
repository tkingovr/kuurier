package bot

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/storage"
)

// Handler provides HTTP endpoints for monitoring and controlling the news bot.
type Handler struct {
	db  *storage.Postgres
	bot *NewsBot
}

// NewHandler creates a new bot handler.
func NewHandler(db *storage.Postgres, bot *NewsBot) *Handler {
	return &Handler{db: db, bot: bot}
}

// TriggerRun manually triggers a news aggregation run (admin only).
func (h *Handler) TriggerRun(c *gin.Context) {
	// Check admin status
	userID := c.GetString("user_id")
	var isAdmin bool
	h.db.Pool().QueryRow(c.Request.Context(), "SELECT COALESCE(is_admin, false) FROM users WHERE id = $1", userID).Scan(&isAdmin)
	if !isAdmin {
		c.JSON(http.StatusForbidden, gin.H{"error": "admin access required"})
		return
	}

	// Run in background
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		if err := h.bot.RunOnce(ctx); err != nil {
			// Already logged inside RunOnce
			_ = err
		}
	}()

	c.JSON(http.StatusAccepted, gin.H{"message": "news aggregation run triggered"})
}

// GetRunHistory returns the recent bot run history (admin only).
func (h *Handler) GetRunHistory(c *gin.Context) {
	userID := c.GetString("user_id")
	var isAdmin bool
	h.db.Pool().QueryRow(c.Request.Context(), "SELECT COALESCE(is_admin, false) FROM users WHERE id = $1", userID).Scan(&isAdmin)
	if !isAdmin {
		c.JSON(http.StatusForbidden, gin.H{"error": "admin access required"})
		return
	}

	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT id, run_type, started_at, completed_at, articles_fetched, articles_posted, errors, status
		 FROM bot_run_log ORDER BY started_at DESC LIMIT 20`,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch run history"})
		return
	}
	defer rows.Close()

	var runs []gin.H
	for rows.Next() {
		var id, runType, status string
		var startedAt time.Time
		var completedAt *time.Time
		var fetched, posted int
		var errors []string

		if err := rows.Scan(&id, &runType, &startedAt, &completedAt, &fetched, &posted, &errors, &status); err != nil {
			continue
		}

		run := gin.H{
			"id":               id,
			"run_type":         runType,
			"started_at":       startedAt,
			"articles_fetched": fetched,
			"articles_posted":  posted,
			"errors":           errors,
			"status":           status,
		}
		if completedAt != nil {
			run["completed_at"] = *completedAt
		}
		runs = append(runs, run)
	}

	c.JSON(http.StatusOK, gin.H{"runs": runs})
}

// GetPostedArticles returns recently posted articles (admin only).
func (h *Handler) GetPostedArticles(c *gin.Context) {
	userID := c.GetString("user_id")
	var isAdmin bool
	h.db.Pool().QueryRow(c.Request.Context(), "SELECT COALESCE(is_admin, false) FROM users WHERE id = $1", userID).Scan(&isAdmin)
	if !isAdmin {
		c.JSON(http.StatusForbidden, gin.H{"error": "admin access required"})
		return
	}

	rows, err := h.db.Pool().Query(c.Request.Context(),
		`SELECT article_url, article_title, source_name, posted_at
		 FROM bot_posted_articles ORDER BY posted_at DESC LIMIT 50`,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch articles"})
		return
	}
	defer rows.Close()

	var articles []gin.H
	for rows.Next() {
		var url, title, source string
		var postedAt time.Time
		if err := rows.Scan(&url, &title, &source, &postedAt); err != nil {
			continue
		}
		articles = append(articles, gin.H{
			"url":       url,
			"title":     title,
			"source":    source,
			"posted_at": postedAt,
		})
	}

	c.JSON(http.StatusOK, gin.H{"articles": articles})
}
