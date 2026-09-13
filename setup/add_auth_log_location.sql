-- Adds real IP + geolocation to auth_log per-attempt (TODO: "Admin login
-- attempts: log IP + location per attempt"). auth_log.ip_guess has existed
-- since add_password_security.sql but was always written blank from the
-- client — real IP isn't visible to browser JS. ip_address/location are now
-- filled server-side by the new log-auth-attempt Edge Function, which reads
-- the request's forwarded-IP header and does a free geo lookup (ipapi.co,
-- no API key). ip_guess is left in place, unused going forward.
ALTER TABLE auth_log ADD COLUMN IF NOT EXISTS ip_address text;
ALTER TABLE auth_log ADD COLUMN IF NOT EXISTS location text;

-- Tracks the auth-log-digest cron's last run, so each digest only reports
-- activity since the previous one (the Telegram report is a 24h rolling
-- window, not full history — full history stays in this admin panel).
INSERT INTO settings(key, value)
SELECT 'auth_log_last_digest_at', now()::text
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'auth_log_last_digest_at');

-- Schedules the new auth-log-digest Edge Function once a day, 5 minutes
-- after the existing daily-health-check job so the two Telegram posts to
-- MeenshaMonitor don't race. Same pg_cron + net.http_post pattern as
-- add_daily_health_check_cron.sql.
--
-- Requires: auth-log-digest deployed with --no-verify-jwt (same reasoning
-- as daily-health-check — it takes no input, is cron-only, and posts only
-- to MeenshaMonitor, never Shalini's chat), and log-auth-attempt deployed
-- normally (called from admin.html with the anon key, like
-- generate-invoice-pdf).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'meensha-auth-log-digest',
  '5 8 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/auth-log-digest',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
