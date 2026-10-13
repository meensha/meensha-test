-- Auto-closes any bot conversation (India + AU) that has had no activity for
-- 30 minutes: resets it to 'idle' with empty data, so a half-finished flow
-- (e.g. an add-photo upload, a kiosk cart) can't sit open forever and block
-- or confuse the next interaction. Runs every 5 minutes, so a session is
-- closed between 30 and 35 minutes after its last activity. updated_at is
-- refreshed by every saveSession() call in both bots.

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'meensha-session-autoclose',
  '*/5 * * * *',
  $$
  UPDATE telegram_sessions
     SET state = 'idle', data = '{}'::jsonb, updated_at = now()
   WHERE state <> 'idle' AND updated_at < now() - interval '30 minutes';
  UPDATE telegram_sessions_au
     SET state = 'idle', data = '{}'::jsonb, updated_at = now()
   WHERE state <> 'idle' AND updated_at < now() - interval '30 minutes';
  $$
);
