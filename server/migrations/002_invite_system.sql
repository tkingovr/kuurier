-- Migration: Invite-Only System
-- Description: Add invite codes table and modify users/vouches for invite tracking

-- ============================================================================
-- INVITE CODES TABLE
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

-- Index for looking up inviter's codes
CREATE INDEX idx_invite_codes_inviter ON invite_codes(inviter_id);

-- Index for code lookup (registration)
CREATE INDEX idx_invite_codes_code ON invite_codes(code);

-- Index for finding expired unused codes (cleanup job)
CREATE INDEX idx_invite_codes_expires ON invite_codes(expires_at)
    WHERE used_at IS NULL;

-- ============================================================================
-- USERS TABLE MODIFICATIONS
-- ============================================================================

-- Track who invited this user
ALTER TABLE users ADD COLUMN invited_by UUID REFERENCES users(id) ON DELETE SET NULL;

-- Track which invite code was used
ALTER TABLE users ADD COLUMN invite_code_used VARCHAR(10);

-- ============================================================================
-- VOUCHES TABLE MODIFICATIONS
-- ============================================================================

-- Distinguish between invite-vouches and manual vouches
-- 'invite' = automatic vouch when someone joins via invite
-- 'manual' = explicit vouch from another user
ALTER TABLE vouches ADD COLUMN vouch_type VARCHAR(20) NOT NULL DEFAULT 'manual';

-- ============================================================================
-- UPDATE EXISTING DATA
-- ============================================================================

-- Mark existing vouches as manual (they existed before invite system)
UPDATE vouches SET vouch_type = 'manual' WHERE vouch_type IS NULL;

-- ============================================================================
-- HELPFUL COMMENTS
-- ============================================================================

COMMENT ON TABLE invite_codes IS 'Invite codes for the invite-only registration system';
COMMENT ON COLUMN invite_codes.code IS 'Format: KUU-XXXXXX (6 alphanumeric chars)';
COMMENT ON COLUMN invite_codes.expires_at IS 'Codes expire 7 days after creation';
COMMENT ON COLUMN invite_codes.used_at IS 'NULL if unused, timestamp when used';
COMMENT ON COLUMN users.invited_by IS 'User ID of the person who invited this user';
COMMENT ON COLUMN users.invite_code_used IS 'The invite code used to join';
COMMENT ON COLUMN vouches.vouch_type IS 'invite = auto-vouch on join, manual = explicit vouch';
