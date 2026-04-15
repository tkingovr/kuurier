-- Migration: 007_event_channels
-- Description: Link events to their chat channels

-- Add channel_id to events table
ALTER TABLE events ADD COLUMN channel_id UUID REFERENCES channels(id) ON DELETE SET NULL;

-- Create index for channel lookup
CREATE INDEX idx_events_channel ON events(channel_id);

-- Add index for event lookups on channels (already exists event_id in channels table)
CREATE INDEX IF NOT EXISTS idx_channels_event ON channels(event_id);
