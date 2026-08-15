-- Schedules the daily-health-check Edge Function to run once a day via
-- pg_cron (built into Supabase). Posts a tech-stack status digest
-- (website/Supabase/Razorpay/GitHub) to MeenshaMonitor (@meenshabot).
--
-- Requires: the daily-health-check function already deployed with JWT
-- verification OFF (`supabase functions deploy daily-health-check
-- --no-verify-jwt`) — it takes no input and returns nothing sensitive
-- (just ✅/⚠️/🔴 status lines), so no auth header is needed for this one
-- call, keeping the cron job below simple with no key embedded anywhere.
-- Also requires settings.telegram_monitor_chat_id to already be set (same
-- key the sales-notification wiring uses).

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Runs at 08:00 UTC (1:30pm IST / 6pm AEST) — adjust the cron expression if
-- a different time suits better once this is running.
SELECT cron.schedule(
  'meensha-daily-health-check',
  '0 8 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/daily-health-check',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
