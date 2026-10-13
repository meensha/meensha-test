-- Daily 08:30 IST (03:00 UTC) reminder of open social-media setup steps to
-- Shalini's bot, until every step in settings.social_actions is marked done.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

INSERT INTO settings (key, value) VALUES ('social_actions', '[
 {"id":"fb_page","label":"Create the Facebook Business Page \"Meensha\" (category: Clothing brand)","url":"https://www.facebook.com/pages/create","done":false},
 {"id":"link_page","label":"Link that Page to Instagram (Instagram app: Edit profile > Page)","url":"https://www.instagram.com/meensha_fabrics/","done":false},
 {"id":"wa_channel","label":"Add the WhatsApp Channel link (Edit profile > Links)","url":"https://whatsapp.com/channel/0029VbC1rowCHDyn3aulnS2v","done":false},
 {"id":"our_story","label":"Post the Our Story graphic as a Story, then save it to a new Our Story highlight","url":"https://www.instagram.com/meensha_fabrics/","done":false},
 {"id":"testimonials","label":"Send 3-5 real customer feedback screenshots (with their OK) for the Testimonials highlight","done":false}
]')
ON CONFLICT (key) DO NOTHING;

SELECT cron.schedule(
  'meensha-social-actions-reminder',
  '0 3 * * *',
  $$
  SELECT net.http_post(
    url := 'https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/social-actions-reminder',
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  $$
);
