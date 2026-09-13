-- Schedules todo-worker-digest 15 minutes after each of the "Meensha TODO
-- worker" cloud routine's own fire times (03:00/07:00/11:00/15:00/19:00/
-- 23:00 UTC = 08:30/12:30/16:30/20:30/00:30/04:30 IST) — long enough for a
-- run to finish committing and pushing before this checks GitHub for new
-- commits on meensha-test2. Same pg_cron + net.http_post pattern as the
-- other digest jobs in this project (see add_returns_pending_digest_cron.sql).

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'meensha-todo-worker-digest',
  '15 3,7,11,15,19,23 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/todo-worker-digest',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
