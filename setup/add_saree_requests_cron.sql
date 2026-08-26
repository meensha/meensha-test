-- Schedules daily-request-reminders to run once a day, same pattern as
-- setup/add_daily_health_check_cron.sql. Requires the function already
-- deployed with JWT verification off (--no-verify-jwt) since pg_cron calls
-- it with no auth header, same reasoning as the health-check cron.

-- pg_cron/pg_net already enabled by add_daily_health_check_cron.sql — this
-- is safe to run even if that hasn't happened yet (idempotent).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Runs at 09:00 UTC (2:30pm IST / 7pm AEST) — deliberately offset from the
-- 08:00 health check so the two digests don't land in the same minute.
SELECT cron.schedule(
  'meensha-daily-request-reminders',
  '0 9 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/daily-request-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
