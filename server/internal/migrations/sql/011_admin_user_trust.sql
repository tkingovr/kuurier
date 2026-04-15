-- Migration 011: Set all existing users to trust score 100 (full privileges)
-- This grants full access including: posting, invites, events, SOS alerts
-- Also adds an is_admin column for future admin-only operations

-- Add admin column
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT false;

-- Set all existing users to max trust and admin status
-- (Currently there is only one user on the platform)
UPDATE users SET trust_score = 100, is_admin = true;

-- Create index for admin lookups
CREATE INDEX IF NOT EXISTS idx_users_is_admin ON users (is_admin) WHERE is_admin = true;
