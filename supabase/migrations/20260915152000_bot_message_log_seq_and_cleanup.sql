-- Timestamp-only ordering isn't reliable when two messages land in the same
-- instant (found via testing) — add a real monotonic sequence for stable
-- chronological ordering regardless of timestamp resolution.
ALTER TABLE bot_message_log ADD COLUMN IF NOT EXISTS seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE INDEX IF NOT EXISTS bot_message_log_chat_seq_idx ON bot_message_log (chat_id, seq);

-- Clean up the smoke-test rows from the previous migration.
DELETE FROM bot_message_log WHERE text LIKE '__TEST__%';

NOTIFY pgrst, 'reload schema';
