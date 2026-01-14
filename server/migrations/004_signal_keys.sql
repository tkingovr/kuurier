-- Migration: Signal Protocol Keys
-- Description: Tables for storing Signal Protocol public keys for E2EE messaging

-- ============================================================================
-- SIGNAL IDENTITY KEYS
-- ============================================================================
-- Stores the public identity key for each user (private key stays on device)

CREATE TABLE signal_identity_keys (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    identity_key    BYTEA NOT NULL,           -- Public identity key (32 bytes for Curve25519)
    registration_id INTEGER NOT NULL,          -- Signal registration ID
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE signal_identity_keys IS 'Public identity keys for Signal Protocol - private keys never leave device';
COMMENT ON COLUMN signal_identity_keys.identity_key IS 'Curve25519 public identity key (32 bytes)';
COMMENT ON COLUMN signal_identity_keys.registration_id IS 'Signal registration ID, randomly generated on device';

-- ============================================================================
-- SIGNED PRE-KEYS
-- ============================================================================
-- Signed pre-keys rotate monthly and are signed by the identity key

CREATE TABLE signal_signed_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id          INTEGER NOT NULL,          -- Identifier for this signed pre-key
    public_key      BYTEA NOT NULL,            -- Curve25519 public key (32 bytes)
    signature       BYTEA NOT NULL,            -- Ed25519 signature (64 bytes)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(user_id, key_id)
);

CREATE INDEX idx_signed_prekeys_user ON signal_signed_prekeys(user_id);

COMMENT ON TABLE signal_signed_prekeys IS 'Signed pre-keys for Signal Protocol X3DH key agreement';
COMMENT ON COLUMN signal_signed_prekeys.signature IS 'Ed25519 signature of public_key by identity key';

-- ============================================================================
-- ONE-TIME PRE-KEYS
-- ============================================================================
-- One-time pre-keys are consumed when establishing a new session

CREATE TABLE signal_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id          INTEGER NOT NULL,          -- Identifier for this pre-key
    public_key      BYTEA NOT NULL,            -- Curve25519 public key (32 bytes)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(user_id, key_id)
);

CREATE INDEX idx_prekeys_user ON signal_prekeys(user_id);
CREATE INDEX idx_prekeys_user_created ON signal_prekeys(user_id, created_at);

COMMENT ON TABLE signal_prekeys IS 'One-time pre-keys for Signal Protocol - consumed on session creation';

-- ============================================================================
-- HELPFUL FUNCTIONS
-- ============================================================================

-- Function to count remaining pre-keys for a user
CREATE OR REPLACE FUNCTION get_prekey_count(uid UUID)
RETURNS INTEGER AS $$
    SELECT COUNT(*)::INTEGER FROM signal_prekeys WHERE user_id = uid;
$$ LANGUAGE SQL STABLE;

-- Function to get and consume one pre-key (atomic operation)
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

COMMENT ON FUNCTION get_prekey_count IS 'Returns count of unused pre-keys for a user';
COMMENT ON FUNCTION consume_prekey IS 'Atomically retrieves and deletes the oldest pre-key for a user';
