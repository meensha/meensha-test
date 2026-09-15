-- Temporary smoke-test rows for bot_message_log / chat_transcript lookup.
-- Cleaned up by the very next migration in this same batch.
INSERT INTO bot_message_log (bot, chat_id, direction, text) VALUES
  ('au', '8918326830', 'in', '__TEST__ how much stock do we have'),
  ('au', '8918326830', 'out', '__TEST__ 5 sarees in stock');
