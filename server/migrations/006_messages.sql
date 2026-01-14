-- Migration: Messages
-- Description: Tables for storing encrypted messages

-- ============================================================================
-- MESSAGES
-- ============================================================================
-- All message content is end-to-end encrypted (server stores only ciphertext)

CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_id      UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    sender_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- E2EE: Server stores only ciphertext, never plaintext
    ciphertext      BYTEA NOT NULL,

    -- Metadata (not encrypted, needed for delivery and display)
    message_type    VARCHAR(20) NOT NULL DEFAULT 'text',  -- text, media, system
    reply_to_id     UUID REFERENCES messages(id) ON DELETE SET NULL,  -- For threaded replies

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at       TIMESTAMPTZ,                          -- NULL if never edited
    deleted_at      TIMESTAMPTZ                           -- Soft delete
);

-- Primary query pattern: fetch recent messages in a channel
CREATE INDEX idx_messages_channel_created ON messages(channel_id, created_at DESC);

-- For fetching user's messages (e.g., for deletion on account delete)
CREATE INDEX idx_messages_sender ON messages(sender_id);

-- For reply lookups
CREATE INDEX idx_messages_reply ON messages(reply_to_id) WHERE reply_to_id IS NOT NULL;

COMMENT ON TABLE messages IS 'E2EE messages - server stores only encrypted ciphertext';
COMMENT ON COLUMN messages.ciphertext IS 'Signal Protocol encrypted message content';
COMMENT ON COLUMN messages.message_type IS 'text = regular message, media = attachment, system = join/leave notices';

-- ============================================================================
-- MESSAGE REACTIONS
-- ============================================================================
-- Reactions are also encrypted to prevent metadata leakage

CREATE TABLE message_reactions (
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    emoji_ciphertext BYTEA NOT NULL,                    -- Encrypted emoji
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX idx_reactions_message ON message_reactions(message_id);

COMMENT ON TABLE message_reactions IS 'Encrypted reactions to messages';

-- ============================================================================
-- MESSAGE ATTACHMENTS
-- ============================================================================
-- Metadata for encrypted file attachments (actual files in MinIO)

CREATE TABLE message_attachments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,

    -- Encrypted metadata (decrypted client-side)
    encrypted_metadata BYTEA NOT NULL,  -- Contains: filename, mime_type, size

    -- Storage reference (MinIO path)
    storage_path    TEXT NOT NULL,

    -- Thumbnail for images/videos (also encrypted)
    encrypted_thumbnail BYTEA,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_attachments_message ON message_attachments(message_id);

COMMENT ON TABLE message_attachments IS 'Encrypted file attachment metadata';

-- ============================================================================
-- MESSAGE DELIVERY RECEIPTS
-- ============================================================================
-- Track message delivery and read status

CREATE TABLE message_receipts (
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    delivered_at    TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,

    PRIMARY KEY (message_id, user_id)
);

CREATE INDEX idx_receipts_user ON message_receipts(user_id, delivered_at DESC);

COMMENT ON TABLE message_receipts IS 'Delivery and read receipts for messages';

-- ============================================================================
-- TYPING INDICATORS (stored in Redis, not here)
-- ============================================================================
-- Note: Typing indicators are ephemeral and stored in Redis, not PostgreSQL

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Get channel message history with pagination
CREATE OR REPLACE FUNCTION get_channel_messages(
    ch_id UUID,
    before_time TIMESTAMPTZ DEFAULT NOW(),
    msg_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
    id UUID,
    sender_id UUID,
    ciphertext BYTEA,
    message_type VARCHAR(20),
    reply_to_id UUID,
    created_at TIMESTAMPTZ,
    edited_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT m.id, m.sender_id, m.ciphertext, m.message_type, m.reply_to_id, m.created_at, m.edited_at
    FROM messages m
    WHERE m.channel_id = ch_id
      AND m.deleted_at IS NULL
      AND m.created_at < before_time
    ORDER BY m.created_at DESC
    LIMIT msg_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Mark all messages in a channel as read for a user
CREATE OR REPLACE FUNCTION mark_channel_read(ch_id UUID, uid UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE channel_members
    SET last_read_at = NOW()
    WHERE channel_id = ch_id AND user_id = uid;

    -- Also update individual message receipts
    INSERT INTO message_receipts (message_id, user_id, read_at)
    SELECT m.id, uid, NOW()
    FROM messages m
    WHERE m.channel_id = ch_id
      AND m.sender_id != uid
      AND m.created_at > COALESCE(
          (SELECT last_read_at FROM channel_members WHERE channel_id = ch_id AND user_id = uid),
          '1970-01-01'::TIMESTAMPTZ
      )
    ON CONFLICT (message_id, user_id) DO UPDATE SET read_at = NOW()
    WHERE message_receipts.read_at IS NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_channel_messages IS 'Paginated message retrieval for a channel';
COMMENT ON FUNCTION mark_channel_read IS 'Marks all messages in a channel as read for a user';
