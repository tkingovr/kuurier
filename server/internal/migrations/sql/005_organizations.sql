-- Migration: Organizations & Channels
-- Description: Tables for Slack-like organization/channel structure for messaging

-- ============================================================================
-- ORGANIZATIONS
-- ============================================================================
-- Organizations are the top-level grouping (e.g., "Freedom Flotilla Coalition")

CREATE TABLE organizations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    avatar_url      TEXT,
    is_public       BOOLEAN NOT NULL DEFAULT true,      -- Can anyone join?
    created_by      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_organizations_public ON organizations(is_public) WHERE is_public = true;
CREATE INDEX idx_organizations_created_by ON organizations(created_by);

COMMENT ON TABLE organizations IS 'Top-level organization groupings for channels';
COMMENT ON COLUMN organizations.is_public IS 'If true, any user can join. If false, requires invite.';

-- ============================================================================
-- ORGANIZATION MEMBERS
-- ============================================================================
-- Tracks membership and roles within organizations

CREATE TABLE organization_members (
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL DEFAULT 'member',  -- admin, moderator, member
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (org_id, user_id)
);

CREATE INDEX idx_org_members_user ON organization_members(user_id);
CREATE INDEX idx_org_members_role ON organization_members(org_id, role);

COMMENT ON COLUMN organization_members.role IS 'admin = full control, moderator = manage channels/members, member = participate';

-- ============================================================================
-- CHANNELS
-- ============================================================================
-- Channels are where conversations happen

CREATE TABLE channels (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID REFERENCES organizations(id) ON DELETE CASCADE,  -- NULL for DMs
    name            VARCHAR(100),                       -- NULL for DMs
    description     TEXT,
    type            VARCHAR(20) NOT NULL,               -- 'public', 'private', 'dm', 'event'
    event_id        UUID REFERENCES events(id) ON DELETE SET NULL,  -- For event-linked channels
    created_by      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- DMs must have org_id = NULL, non-DMs should have org_id
    CONSTRAINT channel_dm_no_org CHECK (
        (type = 'dm' AND org_id IS NULL) OR
        (type != 'dm' AND org_id IS NOT NULL)
    )
);

CREATE INDEX idx_channels_org ON channels(org_id);
CREATE INDEX idx_channels_type ON channels(type);
CREATE INDEX idx_channels_event ON channels(event_id) WHERE event_id IS NOT NULL;

COMMENT ON TABLE channels IS 'Communication channels within organizations or direct messages';
COMMENT ON COLUMN channels.type IS 'public = visible to org, private = invite only, dm = direct message, event = linked to event';

-- ============================================================================
-- CHANNEL MEMBERS
-- ============================================================================
-- Tracks channel membership and read state

CREATE TABLE channel_members (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL DEFAULT 'member',  -- admin, member
    last_read_at    TIMESTAMPTZ,                        -- For unread tracking
    muted_until     TIMESTAMPTZ,                        -- Notification muting
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX idx_channel_members_user ON channel_members(user_id);
CREATE INDEX idx_channel_members_last_read ON channel_members(channel_id, last_read_at);

-- ============================================================================
-- CHANNEL SENDER KEYS
-- ============================================================================
-- Sender keys for group encryption (Signal Protocol Sender Keys)

CREATE TABLE channel_sender_keys (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    distribution_id UUID NOT NULL,                      -- Unique ID for this sender key
    sender_key      BYTEA NOT NULL,                     -- The serialized sender key
    iteration       INTEGER NOT NULL DEFAULT 0,         -- Key chain iteration
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (channel_id, user_id)
);

COMMENT ON TABLE channel_sender_keys IS 'Sender keys for efficient group encryption';

-- ============================================================================
-- ORGANIZATION INVITES
-- ============================================================================
-- Invites for private organizations

CREATE TABLE organization_invites (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    inviter_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invitee_id      UUID REFERENCES users(id) ON DELETE CASCADE,  -- NULL if invite by code
    code            VARCHAR(20),                        -- Optional invite code
    used_at         TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_org_invites_code ON organization_invites(code) WHERE code IS NOT NULL AND used_at IS NULL;
CREATE INDEX idx_org_invites_invitee ON organization_invites(invitee_id) WHERE invitee_id IS NOT NULL AND used_at IS NULL;

-- ============================================================================
-- DM LOOKUP TABLE
-- ============================================================================
-- Fast lookup for existing DM channels between two users

CREATE TABLE dm_channels (
    user1_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user2_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensure user1_id < user2_id for consistent lookups
    PRIMARY KEY (user1_id, user2_id),
    CONSTRAINT dm_user_order CHECK (user1_id < user2_id)
);

COMMENT ON TABLE dm_channels IS 'Fast lookup for DM channels between two users';

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Get or create DM channel between two users
CREATE OR REPLACE FUNCTION get_or_create_dm_channel(uid1 UUID, uid2 UUID)
RETURNS UUID AS $$
DECLARE
    u1 UUID := LEAST(uid1, uid2);
    u2 UUID := GREATEST(uid1, uid2);
    ch_id UUID;
BEGIN
    -- Check if DM channel exists
    SELECT channel_id INTO ch_id FROM dm_channels WHERE user1_id = u1 AND user2_id = u2;

    IF ch_id IS NOT NULL THEN
        RETURN ch_id;
    END IF;

    -- Create new DM channel
    INSERT INTO channels (type, created_by)
    VALUES ('dm', uid1)
    RETURNING id INTO ch_id;

    -- Add both users as members
    INSERT INTO channel_members (channel_id, user_id, role)
    VALUES (ch_id, uid1, 'member'), (ch_id, uid2, 'member');

    -- Add to DM lookup
    INSERT INTO dm_channels (user1_id, user2_id, channel_id)
    VALUES (u1, u2, ch_id);

    RETURN ch_id;
END;
$$ LANGUAGE plpgsql;

-- Count unread messages in a channel for a user
CREATE OR REPLACE FUNCTION get_unread_count(ch_id UUID, uid UUID)
RETURNS INTEGER AS $$
DECLARE
    last_read TIMESTAMPTZ;
    cnt INTEGER;
BEGIN
    SELECT last_read_at INTO last_read FROM channel_members WHERE channel_id = ch_id AND user_id = uid;

    IF last_read IS NULL THEN
        -- Never read, count all messages
        SELECT COUNT(*) INTO cnt FROM messages WHERE channel_id = ch_id AND sender_id != uid;
    ELSE
        SELECT COUNT(*) INTO cnt FROM messages WHERE channel_id = ch_id AND sender_id != uid AND created_at > last_read;
    END IF;

    RETURN COALESCE(cnt, 0);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_or_create_dm_channel IS 'Gets existing or creates new DM channel between two users';
COMMENT ON FUNCTION get_unread_count IS 'Counts unread messages in a channel for a user';
