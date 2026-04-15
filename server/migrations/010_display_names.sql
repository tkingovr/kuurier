-- Migration 010: Add display names to users
-- Users can set a short display name visible to other members in channels.

ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name VARCHAR(30);

CREATE INDEX IF NOT EXISTS idx_users_display_name ON users(display_name) WHERE display_name IS NOT NULL;
