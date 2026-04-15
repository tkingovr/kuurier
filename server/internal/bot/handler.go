package bot

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/storage"
)

// Handler provides HTTP endpoints for monitoring and controlling bots.
// The handler lives in the API process and does not hold bot instances
// directly — triggers are forwarded to the worker process via Redis.
type Handler struct {
	db    *storage.Postgres
	redis *storage.Redis
}

// NewHandler creates a new bot handler.
func NewHandler(db *storage.Postgres, redis *storage.Redis) *Handler {
	return &Handler{db: db, redis: redis}
}

// TriggerRun enqueues a news-aggregation request (admin only).
// The worker process picks it up and runs the bot.
func (h *Handler) TriggerRun(c *gin.Context) {
	if !h.checkAdmin(c) {
		return
	}
	if err := EnqueueTrigger(c.Request.Context(), h.redis, TriggerQueueNews); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to enqueue trigger"})
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"message": "news aggregation run queued"})
}

// TriggerProtestScrape enqueues a protest scrape request (admin only).
func (h *Handler) TriggerProtestScrape(c *gin.Context) {
	if !h.checkAdmin(c) {
		return
	}
	if err := EnqueueTrigger(c.Request.Context(), h.redis, TriggerQueueProtest); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to enqueue trigger"})
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"message": "protest scrape run queued"})
}

// WorkerStatus returns the time since the worker last wrote its
// heartbeat key (admin only). Useful for diagnosing a stuck worker.
func (h *Handler) WorkerStatus(c *gin.Context) {
	if !h.checkAdmin(c) {
		return
	}
	val, err := h.redis.Client().Get(c.Request.Context(), WorkerHeartbeatKey).Result()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"alive": false, "reason": "no recent heartbeat"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"alive":     true,
		"last_seen": val,
	})
}

func (h *Handler) checkAdmin(c *gin.Context) bool {
	userID := c.GetString("user_id")
	var isAdmin bool
	h.db.Pool().QueryRow(c.Request.Context(), "SELECT COALESCE(is_admin, false) FROM users WHERE id = $1", userID).Scan(&isAdmin)
	if !isAdmin {
		c.JSON(http.StatusForbidden, gin.H{"error": "admin access required"})
		return false
	}
	return true
}

// GetRunHistory returns the recent bot run history (admin only).
func (h *Handler) GetRunHistory(c *gin.Context) {
	if !h.checkAdmin(c) {
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
	if !h.checkAdmin(c) {
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
