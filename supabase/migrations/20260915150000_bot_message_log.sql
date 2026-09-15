-- Message-by-message transcript log for both Telegram bots (India + AU),
-- feeding MeenshaMonitor's on-demand "show me X's chat" NL Q&A lookup.
-- Logging starts from deploy time forward only — the Telegram Bot API has
-- no way to retrieve messages from before a bot was listening.

CREATE TABLE IF NOT EXISTS bot_message_log (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bot        text NOT NULL CHECK (bot IN ('india','au')),
  chat_id    text NOT NULL,
  direction  text NOT NULL CHECK (direction IN ('in','out')),
  text       text,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bot_message_log_chat_idx ON bot_message_log (chat_id, created_at);

ALTER TABLE bot_message_log ENABLE ROW LEVEL SECURITY;
-- No policies — service_role only (Edge Functions write/read this directly),
-- same lockdown pattern as telegram_sessions/stock_intake_drafts.

NOTIFY pgrst, 'reload schema';
