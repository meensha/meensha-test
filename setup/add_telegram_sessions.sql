-- Telegram bot skeleton (stage 1 of the build plan — see TELEGRAM_BOT_BUILD_PLAN.md).
-- Conversation state between messages, since the Edge Function is stateless
-- per-invocation. Same lockdown pattern as `orders`/`user_credentials`: RLS
-- on, zero anon/authenticated policies — only the service_role-authenticated
-- Edge Function can read/write this.
CREATE TABLE IF NOT EXISTS telegram_sessions (
  chat_id    bigint PRIMARY KEY,
  state      text NOT NULL DEFAULT 'idle',
  data       jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_sessions ENABLE ROW LEVEL SECURITY;
-- no policies — service_role only

-- Hardcoded allowlist auth: empty until Shalini messages the bot once and
-- her chat_id gets approved into this setting (see build plan section 2).
INSERT INTO settings(key, value)
SELECT 'telegram_authorized_chat_id', ''
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'telegram_authorized_chat_id');

NOTIFY pgrst, 'reload schema';
