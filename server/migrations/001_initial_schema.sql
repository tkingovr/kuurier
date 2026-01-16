-- Kuurier Database Schema
-- Migration: 001_initial_schema
-- Description: Initial database schema with all core tables

-- Enable PostGIS extension for geospatial features
CREATE EXTENSION IF NOT EXISTS postgis;

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- USERS & AUTHENTICATION
-- ============================================

-- Users table (minimal data, privacy-first)
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    public_key      BYTEA NOT NULL UNIQUE,       -- Ed25519 public key (32 bytes)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    trust_score     INT NOT NULL DEFAULT 0,      -- Web of trust score
    is_verified     BOOLEAN NOT NULL DEFAULT FALSE,  -- Can send SOS alerts

    CONSTRAINT public_key_length CHECK (octet_length(public_key) = 32)
);

-- Index for public key lookups (authentication)
CREATE INDEX idx_users_public_key ON users(public_key);

-- Auth challenges for challenge-response authentication
-- SECURITY: challenge_mac provides HMAC integrity protection to prevent forgery
CREATE TABLE auth_challenges (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    challenge       VARCHAR(64) NOT NULL,
    challenge_mac   VARCHAR(64) NOT NULL,  -- HMAC-SHA256 for integrity verification
    expires_at      TIMESTAMPTZ NOT NULL,
    used_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for challenge lookups
CREATE INDEX idx_auth_challenges_user ON auth_challenges(user_id);
CREATE INDEX idx_auth_challenges_lookup ON auth_challenges(user_id, challenge, expires_at);

-- Cleanup old challenges (run periodically)
-- DELETE FROM auth_challenges WHERE expires_at < NOW() - INTERVAL '1 hour';

-- ============================================
-- WEB OF TRUST (VOUCHING SYSTEM)
-- ============================================

-- Vouches table (who trusts whom)
CREATE TABLE vouches (
    voucher_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vouchee_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (voucher_id, vouchee_id),
    CONSTRAINT no_self_vouch CHECK (voucher_id != vouchee_id)
);

-- Index for counting vouches received
CREATE INDEX idx_vouches_vouchee ON vouches(vouchee_id);

-- ============================================
-- TOPICS
-- ============================================

CREATE TABLE topics (
    id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug    VARCHAR(50) UNIQUE NOT NULL,
    name    VARCHAR(100) NOT NULL,
    icon    VARCHAR(50)  -- Emoji or icon name
);

-- Insert default topics
INSERT INTO topics (slug, name, icon) VALUES
    ('climate', 'Climate Action', '🌍'),
    ('labor', 'Labor Rights', '✊'),
    ('housing', 'Housing Justice', '🏠'),
    ('healthcare', 'Healthcare', '🏥'),
    ('education', 'Education', '📚'),
    ('immigration', 'Immigration Rights', '🌐'),
    ('police-reform', 'Police Reform', '⚖️'),
    ('voting-rights', 'Voting Rights', '🗳️'),
    ('lgbtq', 'LGBTQ+ Rights', '🏳️‍🌈'),
    ('racial-justice', 'Racial Justice', '✊🏿'),
    ('womens-rights', 'Women''s Rights', '♀️'),
    ('disability-rights', 'Disability Rights', '♿'),
    ('indigenous', 'Indigenous Rights', '🪶'),
    ('peace', 'Peace & Anti-War', '☮️'),
    ('mutual-aid', 'Mutual Aid', '🤝');

-- ============================================
-- POSTS (NEWS/UPDATES)
-- ============================================

CREATE TABLE posts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content             TEXT NOT NULL,
    source_type         VARCHAR(20) NOT NULL CHECK (source_type IN ('firsthand', 'aggregated', 'mainstream')),
    location            GEOGRAPHY(POINT, 4326),  -- PostGIS point (lon, lat)
    location_name       VARCHAR(200),            -- Human-readable location
    urgency             INT NOT NULL DEFAULT 1 CHECK (urgency BETWEEN 1 AND 3),  -- 1=info, 2=important, 3=urgent
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ,             -- Optional auto-expiry
    verification_score  INT NOT NULL DEFAULT 0,  -- Community verification
    is_flagged          BOOLEAN NOT NULL DEFAULT FALSE,

    CONSTRAINT content_length CHECK (char_length(content) <= 2000)
);

-- Geospatial index for location-based queries
CREATE INDEX idx_posts_location ON posts USING GIST(location);

-- Index for feed queries
CREATE INDEX idx_posts_created ON posts(created_at DESC);
CREATE INDEX idx_posts_author ON posts(author_id);
CREATE INDEX idx_posts_urgency ON posts(urgency);

-- Post-topic associations (many-to-many)
CREATE TABLE post_topics (
    post_id     UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    topic_id    UUID NOT NULL REFERENCES topics(id) ON DELETE CASCADE,

    PRIMARY KEY (post_id, topic_id)
);

CREATE INDEX idx_post_topics_topic ON post_topics(topic_id);

-- Post media (images attached to posts)
CREATE TABLE post_media (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id     UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    media_url   VARCHAR(500) NOT NULL,  -- S3/MinIO URL
    media_type  VARCHAR(20) NOT NULL CHECK (media_type IN ('image', 'video')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_post_media_post ON post_media(post_id);

-- ============================================
-- SUBSCRIPTIONS (USER PREFERENCES)
-- ============================================

CREATE TABLE subscriptions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    topic_id        UUID REFERENCES topics(id) ON DELETE CASCADE,  -- NULL if location-only
    location        GEOGRAPHY(POINT, 4326),                         -- NULL if topic-only
    radius_meters   INT,                                            -- Search radius
    min_urgency     INT NOT NULL DEFAULT 1 CHECK (min_urgency BETWEEN 1 AND 3),
    digest_mode     VARCHAR(20) NOT NULL DEFAULT 'realtime' CHECK (digest_mode IN ('realtime', 'daily', 'weekly')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for subscription lookups
CREATE INDEX idx_subscriptions_user ON subscriptions(user_id);
CREATE INDEX idx_subscriptions_topic ON subscriptions(topic_id);
CREATE INDEX idx_subscriptions_location ON subscriptions USING GIST(location);

-- ============================================
-- EVENTS
-- ============================================

CREATE TABLE events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizer_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    event_type      VARCHAR(50) NOT NULL CHECK (event_type IN ('protest', 'strike', 'fundraiser', 'mutual_aid', 'meeting', 'other')),
    location        GEOGRAPHY(POINT, 4326) NOT NULL,
    location_name   VARCHAR(200),
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_cancelled    BOOLEAN NOT NULL DEFAULT FALSE
);

-- Geospatial index for nearby events
CREATE INDEX idx_events_location ON events USING GIST(location);
CREATE INDEX idx_events_starts ON events(starts_at);
CREATE INDEX idx_events_organizer ON events(organizer_id);

-- Event-topic associations
CREATE TABLE event_topics (
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    topic_id    UUID NOT NULL REFERENCES topics(id) ON DELETE CASCADE,

    PRIMARY KEY (event_id, topic_id)
);

CREATE INDEX idx_event_topics_topic ON event_topics(topic_id);

-- Event RSVPs (anonymous attendance tracking)
CREATE TABLE event_rsvps (
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status      VARCHAR(20) NOT NULL DEFAULT 'going' CHECK (status IN ('going', 'interested', 'not_going')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (event_id, user_id)
);

CREATE INDEX idx_event_rsvps_event ON event_rsvps(event_id);

-- ============================================
-- SOS ALERTS
-- ============================================

CREATE TABLE alerts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    severity        INT NOT NULL CHECK (severity BETWEEN 1 AND 3),  -- 1=awareness, 2=help_needed, 3=emergency
    location        GEOGRAPHY(POINT, 4326) NOT NULL,
    location_name   VARCHAR(200),
    radius_meters   INT NOT NULL DEFAULT 5000,  -- Broadcast radius
    status          VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved', 'false_alarm')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

-- Geospatial index for nearby alerts
CREATE INDEX idx_alerts_location ON alerts USING GIST(location);
CREATE INDEX idx_alerts_status ON alerts(status);
CREATE INDEX idx_alerts_author ON alerts(author_id);

-- Alert responses (who's responding)
CREATE TABLE alert_responses (
    alert_id    UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status      VARCHAR(20) NOT NULL CHECK (status IN ('acknowledged', 'en_route', 'arrived', 'unable')),
    eta_minutes INT,
    location    GEOGRAPHY(POINT, 4326),  -- Responder's current location (optional)
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (alert_id, user_id)
);

CREATE INDEX idx_alert_responses_alert ON alert_responses(alert_id);

-- ============================================
-- PUSH NOTIFICATION TOKENS
-- ============================================

CREATE TABLE push_tokens (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       VARCHAR(500) NOT NULL,
    platform    VARCHAR(20) NOT NULL CHECK (platform IN ('ios', 'android')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, token)
);

CREATE INDEX idx_push_tokens_user ON push_tokens(user_id);

-- ============================================
-- QUIET HOURS SETTINGS
-- ============================================

CREATE TABLE quiet_hours (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    start_time      TIME NOT NULL,        -- e.g., '22:00'
    end_time        TIME NOT NULL,        -- e.g., '08:00'
    timezone        VARCHAR(50) NOT NULL DEFAULT 'UTC',
    allow_emergency BOOLEAN NOT NULL DEFAULT TRUE,  -- Allow emergency alerts during quiet hours
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_quiet_hours_user ON quiet_hours(user_id);

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at trigger to events
CREATE TRIGGER events_updated_at
    BEFORE UPDATE ON events
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- Apply updated_at trigger to alert_responses
CREATE TRIGGER alert_responses_updated_at
    BEFORE UPDATE ON alert_responses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();
