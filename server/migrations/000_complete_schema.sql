-- ============================================================================
-- KUURIER DATABASE SCHEMA - COMPLETE
-- ============================================================================
-- This file combines all migrations into a single schema for first deployment.
-- Run this file on a fresh database to initialize all tables.
--
-- For incremental updates, use the individual migration files in order.
-- Generated: 2026-01-15
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- USERS & AUTHENTICATION
-- ============================================================================

-- Users table (minimal data, privacy-first)
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    public_key      BYTEA NOT NULL UNIQUE,       -- Ed25519 public key (32 bytes)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    trust_score     INT NOT NULL DEFAULT 0,      -- Web of trust score
    is_verified     BOOLEAN NOT NULL DEFAULT FALSE,  -- Can send SOS alerts
    invited_by      UUID REFERENCES users(id) ON DELETE SET NULL,
    invite_code_used VARCHAR(10),

    CONSTRAINT public_key_length CHECK (octet_length(public_key) = 32)
);

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

CREATE INDEX idx_auth_challenges_user ON auth_challenges(user_id);
CREATE INDEX idx_auth_challenges_lookup ON auth_challenges(user_id, challenge, expires_at);

-- ============================================================================
-- INVITE SYSTEM
-- ============================================================================

CREATE TABLE invite_codes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code            VARCHAR(10) NOT NULL UNIQUE,
    inviter_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invitee_id      UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL,
    used_at         TIMESTAMPTZ,
    CONSTRAINT code_format CHECK (code ~ '^KUU-[A-Z0-9]{6}$')
);

CREATE INDEX idx_invite_codes_inviter ON invite_codes(inviter_id);
CREATE INDEX idx_invite_codes_code ON invite_codes(code);
CREATE INDEX idx_invite_codes_expires ON invite_codes(expires_at) WHERE used_at IS NULL;

-- ============================================================================
-- WEB OF TRUST (VOUCHING SYSTEM)
-- ============================================================================

CREATE TABLE vouches (
    voucher_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vouchee_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    vouch_type  VARCHAR(20) NOT NULL DEFAULT 'manual',  -- 'invite' or 'manual'

    PRIMARY KEY (voucher_id, vouchee_id),
    CONSTRAINT no_self_vouch CHECK (voucher_id != vouchee_id)
);

CREATE INDEX idx_vouches_vouchee ON vouches(vouchee_id);

-- ============================================================================
-- TOPICS
-- ============================================================================

CREATE TABLE topics (
    id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug    VARCHAR(50) UNIQUE NOT NULL,
    name    VARCHAR(100) NOT NULL,
    icon    VARCHAR(50)
);

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

-- ============================================================================
-- POSTS (NEWS/UPDATES)
-- ============================================================================

CREATE TABLE posts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content             TEXT NOT NULL,
    source_type         VARCHAR(20) NOT NULL CHECK (source_type IN ('firsthand', 'aggregated', 'mainstream')),
    location            GEOGRAPHY(POINT, 4326),
    location_name       VARCHAR(200),
    urgency             INT NOT NULL DEFAULT 1 CHECK (urgency BETWEEN 1 AND 3),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ,
    verification_score  INT NOT NULL DEFAULT 0,
    is_flagged          BOOLEAN NOT NULL DEFAULT FALSE,

    CONSTRAINT content_length CHECK (char_length(content) <= 2000)
);

CREATE INDEX idx_posts_location ON posts USING GIST(location);
CREATE INDEX idx_posts_created ON posts(created_at DESC);
CREATE INDEX idx_posts_author ON posts(author_id);
CREATE INDEX idx_posts_urgency ON posts(urgency);

CREATE TABLE post_topics (
    post_id     UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    topic_id    UUID NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
    PRIMARY KEY (post_id, topic_id)
);

CREATE INDEX idx_post_topics_topic ON post_topics(topic_id);

CREATE TABLE post_media (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    post_id     UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    media_url   VARCHAR(500) NOT NULL,
    media_type  VARCHAR(20) NOT NULL CHECK (media_type IN ('image', 'video')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_post_media_post ON post_media(post_id);

-- ============================================================================
-- SUBSCRIPTIONS
-- ============================================================================

CREATE TABLE subscriptions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    topic_id        UUID REFERENCES topics(id) ON DELETE CASCADE,
    location        GEOGRAPHY(POINT, 4326),
    radius_meters   INT,
    min_urgency     INT NOT NULL DEFAULT 1 CHECK (min_urgency BETWEEN 1 AND 3),
    digest_mode     VARCHAR(20) NOT NULL DEFAULT 'realtime' CHECK (digest_mode IN ('realtime', 'daily', 'weekly')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_user ON subscriptions(user_id);
CREATE INDEX idx_subscriptions_topic ON subscriptions(topic_id);
CREATE INDEX idx_subscriptions_location ON subscriptions USING GIST(location);

-- ============================================================================
-- EVENTS
-- ============================================================================

CREATE TABLE events (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizer_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title               VARCHAR(200) NOT NULL,
    description         TEXT,
    event_type          VARCHAR(50) NOT NULL CHECK (event_type IN ('protest', 'strike', 'fundraiser', 'mutual_aid', 'meeting', 'other')),
    location            GEOGRAPHY(POINT, 4326) NOT NULL,
    location_name       VARCHAR(200),
    location_visibility VARCHAR(20) NOT NULL DEFAULT 'public' CHECK (location_visibility IN ('public', 'rsvp', 'timed')),
    location_reveal_at  TIMESTAMPTZ,
    location_area       VARCHAR(200),
    starts_at           TIMESTAMPTZ NOT NULL,
    ends_at             TIMESTAMPTZ,
    channel_id          UUID,  -- Forward reference, added after channels table
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_cancelled        BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_events_location ON events USING GIST(location);
CREATE INDEX idx_events_starts ON events(starts_at);
CREATE INDEX idx_events_organizer ON events(organizer_id);
CREATE INDEX idx_events_visibility ON events(location_visibility) WHERE location_visibility = 'public';

CREATE TABLE event_topics (
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    topic_id    UUID NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, topic_id)
);

CREATE INDEX idx_event_topics_topic ON event_topics(topic_id);

CREATE TABLE event_rsvps (
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status      VARCHAR(20) NOT NULL DEFAULT 'going' CHECK (status IN ('going', 'interested', 'not_going')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, user_id)
);

CREATE INDEX idx_event_rsvps_event ON event_rsvps(event_id);

-- ============================================================================
-- SOS ALERTS
-- ============================================================================

CREATE TABLE alerts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    author_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    severity        INT NOT NULL CHECK (severity BETWEEN 1 AND 3),
    location        GEOGRAPHY(POINT, 4326) NOT NULL,
    location_name   VARCHAR(200),
    radius_meters   INT NOT NULL DEFAULT 5000,
    status          VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved', 'false_alarm')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

CREATE INDEX idx_alerts_location ON alerts USING GIST(location);
CREATE INDEX idx_alerts_status ON alerts(status);
CREATE INDEX idx_alerts_author ON alerts(author_id);

CREATE TABLE alert_responses (
    alert_id    UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status      VARCHAR(20) NOT NULL CHECK (status IN ('acknowledged', 'en_route', 'arrived', 'unable')),
    eta_minutes INT,
    location    GEOGRAPHY(POINT, 4326),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (alert_id, user_id)
);

CREATE INDEX idx_alert_responses_alert ON alert_responses(alert_id);

-- ============================================================================
-- PUSH NOTIFICATIONS
-- ============================================================================

CREATE TABLE push_tokens (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       VARCHAR(500) NOT NULL,
    platform    VARCHAR(20) NOT NULL CHECK (platform IN ('ios', 'android')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, token)
);

CREATE INDEX idx_push_tokens_user ON push_tokens(user_id);

-- ============================================================================
-- QUIET HOURS
-- ============================================================================

CREATE TABLE quiet_hours (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
    start_time      TIME NOT NULL,
    end_time        TIME NOT NULL,
    timezone        VARCHAR(50) NOT NULL DEFAULT 'UTC',
    allow_emergency BOOLEAN NOT NULL DEFAULT TRUE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_quiet_hours_user ON quiet_hours(user_id);

-- ============================================================================
-- SIGNAL PROTOCOL KEYS
-- ============================================================================

CREATE TABLE signal_identity_keys (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    identity_key    BYTEA NOT NULL,
    registration_id INTEGER NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE signal_signed_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id          INTEGER NOT NULL,
    public_key      BYTEA NOT NULL,
    signature       BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, key_id)
);

CREATE INDEX idx_signed_prekeys_user ON signal_signed_prekeys(user_id);

CREATE TABLE signal_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id          INTEGER NOT NULL,
    public_key      BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, key_id)
);

CREATE INDEX idx_prekeys_user ON signal_prekeys(user_id);
CREATE INDEX idx_prekeys_user_created ON signal_prekeys(user_id, created_at);

-- ============================================================================
-- ORGANIZATIONS & CHANNELS
-- ============================================================================

CREATE TABLE organizations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    avatar_url      TEXT,
    is_public       BOOLEAN NOT NULL DEFAULT true,
    min_admins      INTEGER NOT NULL DEFAULT 1,
    created_by      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at     TIMESTAMPTZ,
    archived_by     UUID REFERENCES users(id)
);

CREATE INDEX idx_organizations_public ON organizations(is_public) WHERE is_public = true;
CREATE INDEX idx_organizations_created_by ON organizations(created_by);
CREATE INDEX idx_organizations_archived ON organizations(archived_at) WHERE archived_at IS NOT NULL;

CREATE TABLE organization_members (
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL DEFAULT 'member',
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (org_id, user_id)
);

CREATE INDEX idx_org_members_user ON organization_members(user_id);
CREATE INDEX idx_org_members_role ON organization_members(org_id, role);

CREATE TABLE channels (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID REFERENCES organizations(id) ON DELETE CASCADE,
    name            VARCHAR(100),
    description     TEXT,
    type            VARCHAR(20) NOT NULL,
    event_id        UUID REFERENCES events(id) ON DELETE SET NULL,
    created_by      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at     TIMESTAMPTZ,
    archived_by     UUID REFERENCES users(id),

    CONSTRAINT channel_dm_no_org CHECK (
        (type = 'dm' AND org_id IS NULL) OR
        (type = 'event' AND org_id IS NULL) OR
        (type NOT IN ('dm', 'event') AND org_id IS NOT NULL)
    )
);

CREATE INDEX idx_channels_org ON channels(org_id);
CREATE INDEX idx_channels_type ON channels(type);
CREATE INDEX idx_channels_event ON channels(event_id) WHERE event_id IS NOT NULL;
CREATE INDEX idx_channels_archived ON channels(archived_at) WHERE archived_at IS NOT NULL;

-- Add FK from events to channels
ALTER TABLE events ADD CONSTRAINT fk_events_channel FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE SET NULL;
CREATE INDEX idx_events_channel ON events(channel_id);

CREATE TABLE channel_members (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL DEFAULT 'member',
    last_read_at    TIMESTAMPTZ,
    muted_until     TIMESTAMPTZ,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX idx_channel_members_user ON channel_members(user_id);
CREATE INDEX idx_channel_members_last_read ON channel_members(channel_id, last_read_at);

CREATE TABLE channel_sender_keys (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    distribution_id UUID NOT NULL,
    sender_key      BYTEA NOT NULL,
    iteration       INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (channel_id, user_id)
);

CREATE TABLE organization_invites (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    inviter_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invitee_id      UUID REFERENCES users(id) ON DELETE CASCADE,
    code            VARCHAR(20),
    used_at         TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_org_invites_code ON organization_invites(code) WHERE code IS NOT NULL AND used_at IS NULL;
CREATE INDEX idx_org_invites_invitee ON organization_invites(invitee_id) WHERE invitee_id IS NOT NULL AND used_at IS NULL;

CREATE TABLE dm_channels (
    user1_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user2_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user1_id, user2_id),
    CONSTRAINT dm_user_order CHECK (user1_id < user2_id)
);

-- ============================================================================
-- MESSAGES
-- ============================================================================

CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    sender_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ciphertext      BYTEA NOT NULL,
    message_type    VARCHAR(20) NOT NULL DEFAULT 'text',
    reply_to_id     UUID REFERENCES messages(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at       TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX idx_messages_channel_created ON messages(channel_id, created_at DESC);
CREATE INDEX idx_messages_sender ON messages(sender_id);
CREATE INDEX idx_messages_reply ON messages(reply_to_id) WHERE reply_to_id IS NOT NULL;

CREATE TABLE message_reactions (
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji_ciphertext BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX idx_reactions_message ON message_reactions(message_id);

CREATE TABLE message_attachments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id          UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    encrypted_metadata  BYTEA NOT NULL,
    storage_path        TEXT NOT NULL,
    encrypted_thumbnail BYTEA,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_attachments_message ON message_attachments(message_id);

CREATE TABLE message_receipts (
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    delivered_at    TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,
    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX idx_receipts_user ON message_receipts(user_id, delivered_at DESC);

-- ============================================================================
-- GOVERNANCE
-- ============================================================================

CREATE TABLE admin_transfer_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    from_user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at    TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    CONSTRAINT unique_pending_transfer UNIQUE (org_id, from_user_id, to_user_id, status)
);

CREATE INDEX idx_admin_transfers_pending ON admin_transfer_requests(to_user_id, status) WHERE status = 'pending';

CREATE TABLE conversation_visibility (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hidden_at       TIMESTAMPTZ,
    archived_at     TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX idx_conv_visibility_hidden ON conversation_visibility(user_id, hidden_at) WHERE hidden_at IS NOT NULL;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Update timestamp trigger
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER events_updated_at BEFORE UPDATE ON events FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER alert_responses_updated_at BEFORE UPDATE ON alert_responses FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Signal Protocol functions
CREATE OR REPLACE FUNCTION get_prekey_count(uid UUID)
RETURNS INTEGER AS $$
    SELECT COUNT(*)::INTEGER FROM signal_prekeys WHERE user_id = uid;
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION consume_prekey(uid UUID)
RETURNS TABLE(key_id INTEGER, public_key BYTEA) AS $$
    DELETE FROM signal_prekeys
    WHERE id = (
        SELECT id FROM signal_prekeys
        WHERE user_id = uid
        ORDER BY created_at ASC
        LIMIT 1
    )
    RETURNING signal_prekeys.key_id, signal_prekeys.public_key;
$$ LANGUAGE SQL;

-- DM channel helper
CREATE OR REPLACE FUNCTION get_or_create_dm_channel(uid1 UUID, uid2 UUID)
RETURNS UUID AS $$
DECLARE
    u1 UUID := LEAST(uid1, uid2);
    u2 UUID := GREATEST(uid1, uid2);
    ch_id UUID;
BEGIN
    SELECT channel_id INTO ch_id FROM dm_channels WHERE user1_id = u1 AND user2_id = u2;
    IF ch_id IS NOT NULL THEN
        RETURN ch_id;
    END IF;

    INSERT INTO channels (type, created_by) VALUES ('dm', uid1) RETURNING id INTO ch_id;
    INSERT INTO channel_members (channel_id, user_id, role) VALUES (ch_id, uid1, 'member'), (ch_id, uid2, 'member');
    INSERT INTO dm_channels (user1_id, user2_id, channel_id) VALUES (u1, u2, ch_id);
    RETURN ch_id;
END;
$$ LANGUAGE plpgsql;

-- Unread count
CREATE OR REPLACE FUNCTION get_unread_count(ch_id UUID, uid UUID)
RETURNS INTEGER AS $$
DECLARE
    last_read TIMESTAMPTZ;
    cnt INTEGER;
BEGIN
    SELECT last_read_at INTO last_read FROM channel_members WHERE channel_id = ch_id AND user_id = uid;
    IF last_read IS NULL THEN
        SELECT COUNT(*) INTO cnt FROM messages WHERE channel_id = ch_id AND sender_id != uid;
    ELSE
        SELECT COUNT(*) INTO cnt FROM messages WHERE channel_id = ch_id AND sender_id != uid AND created_at > last_read;
    END IF;
    RETURN COALESCE(cnt, 0);
END;
$$ LANGUAGE plpgsql STABLE;

-- Message history
CREATE OR REPLACE FUNCTION get_channel_messages(
    ch_id UUID,
    before_time TIMESTAMPTZ DEFAULT NOW(),
    msg_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
    id UUID, sender_id UUID, ciphertext BYTEA, message_type VARCHAR(20),
    reply_to_id UUID, created_at TIMESTAMPTZ, edited_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT m.id, m.sender_id, m.ciphertext, m.message_type, m.reply_to_id, m.created_at, m.edited_at
    FROM messages m
    WHERE m.channel_id = ch_id AND m.deleted_at IS NULL AND m.created_at < before_time
    ORDER BY m.created_at DESC LIMIT msg_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Mark channel read
CREATE OR REPLACE FUNCTION mark_channel_read(ch_id UUID, uid UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE channel_members SET last_read_at = NOW() WHERE channel_id = ch_id AND user_id = uid;
    INSERT INTO message_receipts (message_id, user_id, read_at)
    SELECT m.id, uid, NOW() FROM messages m
    WHERE m.channel_id = ch_id AND m.sender_id != uid
      AND m.created_at > COALESCE((SELECT last_read_at FROM channel_members WHERE channel_id = ch_id AND user_id = uid), '1970-01-01'::TIMESTAMPTZ)
    ON CONFLICT (message_id, user_id) DO UPDATE SET read_at = NOW() WHERE message_receipts.read_at IS NULL;
END;
$$ LANGUAGE plpgsql;

-- Organization helpers
CREATE OR REPLACE FUNCTION org_admin_count(org UUID)
RETURNS INTEGER AS $$
    SELECT COUNT(*)::INTEGER FROM organization_members WHERE org_id = org AND role = 'admin';
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION org_can_hard_delete(org UUID, requesting_user UUID)
RETURNS BOOLEAN AS $$
DECLARE
    member_count INTEGER;
    has_messages BOOLEAN;
    is_sole_admin BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO member_count FROM organization_members WHERE org_id = org AND user_id != requesting_user;
    SELECT EXISTS(SELECT 1 FROM messages m JOIN channels c ON m.channel_id = c.id WHERE c.org_id = org) INTO has_messages;
    SELECT EXISTS(SELECT 1 FROM organization_members WHERE org_id = org AND user_id = requesting_user AND role = 'admin') INTO is_sole_admin;
    RETURN is_sole_admin AND member_count = 0 AND NOT has_messages;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION user_can_leave_org(org UUID, leaving_user UUID)
RETURNS BOOLEAN AS $$
DECLARE
    user_role VARCHAR(20);
    admin_count INTEGER;
    member_count INTEGER;
BEGIN
    SELECT role INTO user_role FROM organization_members WHERE org_id = org AND user_id = leaving_user;
    IF user_role IS NULL THEN RETURN FALSE; END IF;
    IF user_role != 'admin' THEN RETURN TRUE; END IF;
    SELECT COUNT(*) INTO admin_count FROM organization_members WHERE org_id = org AND role = 'admin';
    SELECT COUNT(*) INTO member_count FROM organization_members WHERE org_id = org;
    IF admin_count = 1 AND member_count > 1 THEN RETURN FALSE; END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE users IS 'User accounts with Ed25519 public keys for authentication';
COMMENT ON TABLE auth_challenges IS 'Challenge-response authentication with HMAC integrity protection';
COMMENT ON TABLE vouches IS 'Web of trust - users vouch for each other';
COMMENT ON TABLE invite_codes IS 'Invite codes for the invite-only registration system';
COMMENT ON TABLE signal_identity_keys IS 'Signal Protocol identity keys (private keys stay on device)';
COMMENT ON TABLE signal_prekeys IS 'One-time pre-keys for Signal Protocol X3DH';
COMMENT ON TABLE organizations IS 'Top-level organization groupings';
COMMENT ON TABLE channels IS 'Communication channels (public, private, DM, event-linked)';
COMMENT ON TABLE messages IS 'E2EE messages - server stores only ciphertext';
COMMENT ON TABLE alerts IS 'SOS emergency alerts with geospatial broadcast';

-- ============================================================================
-- BOOTSTRAP DATA
-- ============================================================================

-- Bootstrap user (user zero) - required to generate initial invite codes
-- This user cannot log in (invalid public key) but can invite the first real users
INSERT INTO users (id, public_key, trust_score, is_verified, created_at)
VALUES (
    '00000000-0000-0000-0000-000000000000',
    decode('0000000000000000000000000000000000000000000000000000000000000000', 'hex'),
    100,
    true,
    NOW()
) ON CONFLICT (id) DO NOTHING;

-- Initial invite code (valid for 1 year)
INSERT INTO invite_codes (id, code, inviter_id, created_at, expires_at)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'KUU-BOOT01',
    '00000000-0000-0000-0000-000000000000',
    NOW(),
    NOW() + INTERVAL '365 days'
) ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
