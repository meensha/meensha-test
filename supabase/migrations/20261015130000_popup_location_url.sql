-- Optional Google Maps (or any map) link for a Pop-Up Event, shown as a
-- pin-icon hyperlink next to the existing plain-text `location` venue name.
ALTER TABLE popups ADD COLUMN IF NOT EXISTS location_url text;
