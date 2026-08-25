-- Real date columns on popups (events), alongside the existing free-text
-- `dates` display string. Needed so the app can actually validate/compare
-- dates (no-past-date, end >= start) and so the event-photo-submission
-- window (separate feature) can check "is today within this event's run."
ALTER TABLE popups ADD COLUMN IF NOT EXISTS date_from date;
ALTER TABLE popups ADD COLUMN IF NOT EXISTS date_to date;

NOTIFY pgrst, 'reload schema';
