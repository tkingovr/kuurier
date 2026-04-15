-- Migration 014: Feed materialization
--
-- Precomputed feed per user per feed-type. Written by the
-- FeedMaterializer job in the worker process every few minutes;
-- read by the API's GetFeedV2 handler on every request.
--
-- Replaces the previous pattern of loading 1200 rows into Go memory
-- and ranking them on every feed request.

CREATE TABLE IF NOT EXISTS materialized_feeds (
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    feed_type    VARCHAR(16) NOT NULL,
    post_id      UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    score        DOUBLE PRECISION NOT NULL,
    why          TEXT[],
    computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, feed_type, post_id)
);

-- Primary read path: "give me the top N for this user/feed by score".
CREATE INDEX IF NOT EXISTS idx_mf_read
    ON materialized_feeds (user_id, feed_type, score DESC);

-- Used by the materializer to detect stale rows to re-score or delete.
CREATE INDEX IF NOT EXISTS idx_mf_computed_at
    ON materialized_feeds (computed_at);

-- Track when each user was last seen, so the materializer can
-- prioritize active users over dormant accounts.
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_last_active_at
    ON users (last_active_at DESC)
    WHERE last_active_at IS NOT NULL;
