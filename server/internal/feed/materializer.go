// Feed materialization: precompute ranked feeds for active users so
// GetFeedV2 becomes a simple indexed SELECT instead of loading 1200
// rows and scoring them in Go per request.
//
// The worker process calls RunOnce on a ~5 minute tick. It:
//   1. Lists users with last_active_at within the recent window.
//   2. For each user × supported feed type, fetches candidates,
//      runs the same ranker used in the live path, and UPSERTs into
//      materialized_feeds.
//   3. Deletes stale rows for users that have gone dormant.
//
// We reuse the Handler's helpers (fetchFeedCandidates, rankFeedCandidates,
// getUserSubscriptions) so there's exactly one scoring implementation
// that both paths share.
package feed

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/metrics"
	"github.com/kuurier/server/internal/storage"
)

// Materializer runs the feed precomputation job. Constructed once in
// the worker's main and Run()-ed on a schedule.
type Materializer struct {
	// Reuse the Handler so we don't duplicate the ranking logic.
	h *Handler
}

// NewMaterializer returns a Materializer backed by a feed Handler
// that shares its DB pool + config with the rest of the package.
func NewMaterializer(cfg *config.Config, db *storage.Postgres, redis *storage.Redis) *Materializer {
	return &Materializer{h: NewHandler(cfg, db, redis)}
}

// RunOnce computes materialized feeds for recently-active users.
//
// Currently materializes the default "for_you" feed only. Following
// feeds ("local", "crisis", "following") are small-query-driven and
// time-sensitive — caching them buys less.
func (m *Materializer) RunOnce(ctx context.Context) error {
	start := time.Now()
	users, err := m.activeUsers(ctx, 7*24*time.Hour)
	if err != nil {
		return fmt.Errorf("list active users: %w", err)
	}
	slog.InfoContext(ctx, "feed materialization starting",
		slog.Int("active_users", len(users)))

	// Candidate fetch is the same for everybody; compute it once.
	candidates, err := m.h.fetchFeedCandidates(ctx, 1200)
	if err != nil {
		return fmt.Errorf("fetch candidates: %w", err)
	}

	feedType := FeedTypeForYou

	for _, userID := range users {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := m.materializeFor(ctx, userID, feedType, candidates); err != nil {
			// Per-user failures shouldn't kill the whole pass.
			slog.WarnContext(ctx, "materialize user failed",
				slog.String("user_id", userID),
				slog.String("error", err.Error()))
			continue
		}
	}

	// Clean up entries for users that have gone dormant.
	cleaned, err := m.pruneStale(ctx, 72*time.Hour)
	if err != nil {
		slog.WarnContext(ctx, "stale prune failed", slog.String("error", err.Error()))
	}
	duration := time.Since(start)
	metrics.FeedMaterializationDuration.Observe(duration.Seconds())

	slog.InfoContext(ctx, "feed materialization complete",
		slog.Int("users", len(users)),
		slog.Int("pruned", cleaned),
		slog.Int64("duration_ms", duration.Milliseconds()))
	return nil
}

func (m *Materializer) activeUsers(ctx context.Context, since time.Duration) ([]string, error) {
	rows, err := m.h.db.Pool().Query(ctx, `
		SELECT id FROM users
		WHERE last_active_at > NOW() - $1::interval
	`, fmt.Sprintf("%d seconds", int(since.Seconds())))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (m *Materializer) materializeFor(ctx context.Context, userID string, feedType FeedType, candidates []postCandidate) error {
	subs, topicNames, err := m.h.getUserSubscriptions(ctx, userID)
	if err != nil {
		return fmt.Errorf("get subscriptions: %w", err)
	}
	scored := m.h.rankFeedCandidates(feedType, candidates, subs, topicNames, nil, nil, 50000, 0)

	// Cap what we persist — clients page through but 200 items is
	// enough headroom for deep scrolling without bloating the table.
	const maxItems = 200
	if len(scored) > maxItems {
		scored = scored[:maxItems]
	}

	// Atomic swap: delete old rows for this user+feed_type and insert new.
	tx, err := m.h.db.Pool().Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx,
		`DELETE FROM materialized_feeds WHERE user_id = $1 AND feed_type = $2`,
		userID, string(feedType)); err != nil {
		return err
	}

	for _, item := range scored {
		if item.post == nil {
			continue
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO materialized_feeds (user_id, feed_type, post_id, score, why, computed_at)
			VALUES ($1, $2, $3, $4, $5, NOW())
		`, userID, string(feedType), item.post.id, item.score, item.why); err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// serveMaterialized writes a feed response from the materialized_feeds
// table. Returns true if it served a response; false means the
// caller should fall back to the live compute path (no materialized
// rows exist yet for this user, or they're too stale).
func (h *Handler) serveMaterialized(c *gin.Context, userID string, feedType FeedType, limit, offset int) bool {
	ctx := c.Request.Context()

	// Staleness check: if the newest row is older than 10 minutes,
	// don't serve it — the materializer missed a tick (crash? deploy?
	// new user) and the user gets the fresh live result.
	var newest *time.Time
	err := h.db.Pool().QueryRow(ctx, `
		SELECT MAX(computed_at) FROM materialized_feeds
		WHERE user_id = $1 AND feed_type = $2
	`, userID, string(feedType)).Scan(&newest)
	if err != nil || newest == nil || time.Since(*newest) > 10*time.Minute {
		return false
	}

	rows, err := h.db.Pool().Query(ctx, `
		SELECT mf.post_id, mf.score, mf.why,
		       p.author_id, p.content, p.source_type,
		       ST_Y(p.location::geometry) as lat,
		       ST_X(p.location::geometry) as lon,
		       p.location_name, p.urgency, p.created_at, p.verification_score,
		       COALESCE(u.trust_score, 0) AS trust_score
		FROM materialized_feeds mf
		JOIN posts p ON p.id = mf.post_id
		LEFT JOIN users u ON u.id = p.author_id
		WHERE mf.user_id = $1 AND mf.feed_type = $2
		  AND p.is_flagged = false
		ORDER BY mf.score DESC
		LIMIT $3 OFFSET $4
	`, userID, string(feedType), limit, offset)
	if err != nil {
		return false
	}
	defer rows.Close()

	scored := make([]scoredFeedItem, 0, limit)
	for rows.Next() {
		var post postCandidate
		var score float64
		var why []string
		if err := rows.Scan(
			&post.id, &score, &why,
			&post.authorID, &post.content, &post.sourceType,
			&post.latitude, &post.longitude,
			&post.locationName, &post.urgency, &post.createdAt, &post.verificationScore,
			&post.authorTrustScore,
		); err != nil {
			continue
		}
		scored = append(scored, scoredFeedItem{
			score:    score,
			itemType: "post",
			post:     &post,
			why:      why,
		})
	}

	items := h.buildFeedResponseItems(ctx, scored)
	nextOffset := offset + len(items)
	if len(items) < limit {
		nextOffset = -1
	}

	c.JSON(http.StatusOK, gin.H{
		"items":       items,
		"limit":       limit,
		"offset":      offset,
		"next_offset": nextOffset,
		"source":      "materialized",
	})
	return true
}

func (m *Materializer) pruneStale(ctx context.Context, olderThan time.Duration) (int, error) {
	res, err := m.h.db.Pool().Exec(ctx, `
		DELETE FROM materialized_feeds
		WHERE computed_at < NOW() - $1::interval
	`, fmt.Sprintf("%d seconds", int(olderThan.Seconds())))
	if err != nil {
		return 0, err
	}
	return int(res.RowsAffected()), nil
}
