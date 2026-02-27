-- Migration 009: Multi-device support
-- Adds device tracking and device linking for desktop/web clients

-- Devices table: tracks all devices for a user
CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_type VARCHAR(20) NOT NULL CHECK (device_type IN ('ios', 'android', 'desktop', 'web')),
    device_name VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT true,
    UNIQUE(user_id, id)
);

CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id);

-- Device link requests: temporary relay for QR code device linking
CREATE TABLE IF NOT EXISTS device_link_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL,
    encrypted_payload TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes'),
    consumed BOOLEAN DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_device_link_device_id ON device_link_requests(device_id);
CREATE INDEX IF NOT EXISTS idx_device_link_expires ON device_link_requests(expires_at);

-- Add device_id to signal key tables for per-device key bundles
ALTER TABLE signal_identity_keys ADD COLUMN IF NOT EXISTS device_id UUID REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE signal_signed_prekeys ADD COLUMN IF NOT EXISTS device_id UUID REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE signal_prekeys ADD COLUMN IF NOT EXISTS device_id UUID REFERENCES devices(id) ON DELETE CASCADE;

-- Update unique constraints for signal keys to include device_id
-- Drop old primary key on signal_identity_keys and add composite
-- (These are safe: existing rows with NULL device_id represent the primary mobile device)
DO $$
BEGIN
    -- Only drop and recreate if device_id column was just added (no existing device-aware constraint)
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'signal_identity_keys_user_device_unique'
    ) THEN
        -- Create unique constraint for user + device combinations
        CREATE UNIQUE INDEX signal_identity_keys_user_device_unique
            ON signal_identity_keys(user_id, COALESCE(device_id, '00000000-0000-0000-0000-000000000000'::uuid));
    END IF;
END
$$;

-- Function to clean up expired link requests
CREATE OR REPLACE FUNCTION cleanup_expired_link_requests()
RETURNS void AS $$
BEGIN
    DELETE FROM device_link_requests WHERE expires_at < NOW() OR consumed = true;
END;
$$ LANGUAGE plpgsql;

-- Migrate existing users: create a default "primary" device for each existing user
-- This ensures backwards compatibility
INSERT INTO devices (user_id, device_type, device_name, created_at, last_active_at, is_active)
SELECT id, 'ios', 'Primary Device', created_at, NOW(), true
FROM users
WHERE id != '00000000-0000-0000-0000-000000000000'
ON CONFLICT DO NOTHING;
