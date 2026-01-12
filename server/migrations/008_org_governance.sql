-- Migration: 008_org_governance
-- Description: Organization governance features for resilient leadership

-- ============================================================================
-- ORGANIZATION GOVERNANCE COLUMNS
-- ============================================================================

-- Add archived status to organizations
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES users(id);

-- Add minimum admins requirement
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS min_admins INTEGER NOT NULL DEFAULT 1;

-- Create index for archived orgs
CREATE INDEX IF NOT EXISTS idx_organizations_archived ON organizations(archived_at) WHERE archived_at IS NOT NULL;

-- ============================================================================
-- ADMIN TRANSFER REQUESTS (for ownership handoff)
-- ============================================================================

CREATE TABLE IF NOT EXISTS admin_transfer_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    from_user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending, accepted, rejected, expired
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at    TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),

    CONSTRAINT unique_pending_transfer UNIQUE (org_id, from_user_id, to_user_id, status)
);

CREATE INDEX idx_admin_transfers_pending ON admin_transfer_requests(to_user_id, status)
    WHERE status = 'pending';

COMMENT ON TABLE admin_transfer_requests IS 'Tracks admin role transfer requests between users';

-- ============================================================================
-- DM VISIBILITY (hide without delete)
-- ============================================================================

-- Track hidden/archived conversations per user
CREATE TABLE IF NOT EXISTS conversation_visibility (
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hidden_at       TIMESTAMPTZ,           -- If set, conversation is hidden for this user
    archived_at     TIMESTAMPTZ,           -- Soft archive (can be restored)
    deleted_at      TIMESTAMPTZ,           -- Hard delete (permanent for this user)

    PRIMARY KEY (channel_id, user_id)
);

CREATE INDEX idx_conv_visibility_hidden ON conversation_visibility(user_id, hidden_at)
    WHERE hidden_at IS NOT NULL;

COMMENT ON TABLE conversation_visibility IS 'Per-user visibility settings for conversations (hide/archive without deleting for others)';

-- ============================================================================
-- CHANNEL ARCHIVE
-- ============================================================================

-- Add archived status to channels
ALTER TABLE channels ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES users(id);

CREATE INDEX IF NOT EXISTS idx_channels_archived ON channels(archived_at) WHERE archived_at IS NOT NULL;

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Count admins in an organization
CREATE OR REPLACE FUNCTION org_admin_count(org UUID)
RETURNS INTEGER AS $$
    SELECT COUNT(*)::INTEGER
    FROM organization_members
    WHERE org_id = org AND role = 'admin';
$$ LANGUAGE SQL STABLE;

-- Check if org can be hard deleted (no other members, no active channels with messages)
CREATE OR REPLACE FUNCTION org_can_hard_delete(org UUID, requesting_user UUID)
RETURNS BOOLEAN AS $$
DECLARE
    member_count INTEGER;
    has_messages BOOLEAN;
    is_sole_admin BOOLEAN;
BEGIN
    -- Count non-requesting-user members
    SELECT COUNT(*) INTO member_count
    FROM organization_members
    WHERE org_id = org AND user_id != requesting_user;

    -- Check if there are any messages in org channels
    SELECT EXISTS(
        SELECT 1 FROM messages m
        JOIN channels c ON m.channel_id = c.id
        WHERE c.org_id = org
    ) INTO has_messages;

    -- Check if requesting user is admin
    SELECT EXISTS(
        SELECT 1 FROM organization_members
        WHERE org_id = org AND user_id = requesting_user AND role = 'admin'
    ) INTO is_sole_admin;

    -- Can only hard delete if: sole admin, no other members, and no messages
    RETURN is_sole_admin AND member_count = 0 AND NOT has_messages;
END;
$$ LANGUAGE plpgsql STABLE;

-- Check if user can leave org (must not be sole admin if org has multiple members)
CREATE OR REPLACE FUNCTION user_can_leave_org(org UUID, leaving_user UUID)
RETURNS BOOLEAN AS $$
DECLARE
    user_role VARCHAR(20);
    admin_count INTEGER;
    member_count INTEGER;
BEGIN
    -- Get user's role
    SELECT role INTO user_role
    FROM organization_members
    WHERE org_id = org AND user_id = leaving_user;

    -- If not a member, can't leave
    IF user_role IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Non-admins can always leave
    IF user_role != 'admin' THEN
        RETURN TRUE;
    END IF;

    -- Count admins and total members
    SELECT COUNT(*) INTO admin_count
    FROM organization_members
    WHERE org_id = org AND role = 'admin';

    SELECT COUNT(*) INTO member_count
    FROM organization_members
    WHERE org_id = org;

    -- Sole admin can leave only if they're the only member
    IF admin_count = 1 AND member_count > 1 THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION org_admin_count IS 'Returns the number of admins in an organization';
COMMENT ON FUNCTION org_can_hard_delete IS 'Checks if an organization can be permanently deleted';
COMMENT ON FUNCTION user_can_leave_org IS 'Checks if a user can leave an organization (prevents orphaned orgs)';
