-- Migration 012: News bot system user and tracking table
-- Creates a dedicated system user for the news bot and a table to track posted articles

-- Create the news bot system user with a well-known ID
-- Uses a zeroed public key (not a real Ed25519 key, so no one can auth as this user)
INSERT INTO users (id, public_key, created_at, trust_score, is_verified, display_name, is_admin)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    decode('0000000000000000000000000000000000000000000000000000000000000000', 'hex'),
    NOW(),
    100,
    true,
    'Kuurier News Bot',
    false
) ON CONFLICT (id) DO NOTHING;

-- Track which articles have already been posted to avoid duplicates
CREATE TABLE IF NOT EXISTS bot_posted_articles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    article_url TEXT NOT NULL UNIQUE,
    article_title TEXT NOT NULL,
    post_id UUID REFERENCES posts(id) ON DELETE SET NULL,
    source_name TEXT NOT NULL,
    posted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bot_posted_articles_url ON bot_posted_articles (article_url);
CREATE INDEX IF NOT EXISTS idx_bot_posted_articles_posted_at ON bot_posted_articles (posted_at DESC);

-- Bot run log for observability
CREATE TABLE IF NOT EXISTS bot_run_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type TEXT NOT NULL,        -- 'news_aggregation'
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    articles_fetched INT DEFAULT 0,
    articles_posted INT DEFAULT 0,
    errors TEXT[],
    status TEXT NOT NULL DEFAULT 'running' -- 'running', 'completed', 'failed'
);
