-- Free-standing quick notes staff leave via the Telegram bot's Maintenance
-- > Note option — not attached to any sale/vendor/item, just a timestamped
-- remark that shows up on the admin.html dashboard as a running log.
CREATE TABLE IF NOT EXISTS bot_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  text         text NOT NULL,
  submitted_by text,
  created_at   timestamptz DEFAULT now()
);
ALTER TABLE bot_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "all_anon" ON bot_notes;
CREATE POLICY "all_anon" ON bot_notes FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON bot_notes;
CREATE POLICY "all_auth" ON bot_notes FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
