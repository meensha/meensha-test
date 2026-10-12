-- Schedules the post-suggestion-nudge Edge Function to run twice a week
-- (Monday + Thursday, 9:30am IST = 04:00 UTC), enforcing the social media
-- growth plan's ~2x/week posting cadence target. Posts a fresh "Suggest a
-- post" draft to every active India owner chat that isn't already mid-flow
-- in something else. Posting itself stays manual — this only nudges the
-- draft-and-revise loop, never auto-posts.

CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

SELECT cron.schedule(
  'meensha-post-suggestion-nudge',
  '0 4 * * 1,4',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/post-suggestion-nudge',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);

NOTIFY pgrst, 'reload schema';
