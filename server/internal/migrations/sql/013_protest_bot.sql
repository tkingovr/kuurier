-- Migration 013: Protest scraper bot — imports events from findaprotest.info
-- Reuses the existing news bot system user (00000000-0000-0000-0000-000000000001)
-- to create events in the events table.

-- Track which protests have already been scraped to avoid duplicates
CREATE TABLE IF NOT EXISTS bot_scraped_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id TEXT NOT NULL,              -- unique ID from the source site
    source_url TEXT NOT NULL DEFAULT '',   -- link to the original event page
    event_id UUID REFERENCES events(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    scraped_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_id)
);

CREATE INDEX IF NOT EXISTS idx_bot_scraped_events_source_id ON bot_scraped_events (source_id);
CREATE INDEX IF NOT EXISTS idx_bot_scraped_events_scraped_at ON bot_scraped_events (scraped_at DESC);
