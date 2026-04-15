-- Migration: Add location privacy controls to events
-- This allows organizers to control when/if event location is revealed

-- Location visibility options:
-- 'public'    - Location always visible, shows on map
-- 'rsvp'      - Location visible only after RSVP
-- 'timed'     - Location hidden until reveal_at timestamp
ALTER TABLE events ADD COLUMN location_visibility VARCHAR(20) NOT NULL DEFAULT 'public'
    CHECK (location_visibility IN ('public', 'rsvp', 'timed'));

-- For timed visibility: when to reveal the location (typically 1 hour before event)
ALTER TABLE events ADD COLUMN location_reveal_at TIMESTAMPTZ;

-- Optional: A general area description shown when exact location is hidden
-- e.g., "Downtown Oakland" or "East Bay" - gives attendees a rough idea without exact address
ALTER TABLE events ADD COLUMN location_area VARCHAR(200);

-- Add index for filtering public events (for map display)
CREATE INDEX idx_events_visibility ON events(location_visibility) WHERE location_visibility = 'public';

-- Update existing events to be public (backward compatible)
UPDATE events SET location_visibility = 'public' WHERE location_visibility IS NULL;
