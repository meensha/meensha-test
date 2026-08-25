-- Schedules the returns-pending-digest Edge Function to run daily at
-- 10:00 IST via pg_cron, same mechanism as
-- setup/add_daily_health_check_cron.sql. Requires: the function already
-- deployed with JWT verification OFF (`supabase functions deploy
-- returns-pending-digest --no-verify-jwt`) — pg_cron's net.http_post call
-- carries no auth header, same reasoning as the health-check job.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 10:00 IST = 04:30 UTC.
SELECT cron.schedule(
  'meensha-returns-pending-digest',
  '30 4 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/returns-pending-digest',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
