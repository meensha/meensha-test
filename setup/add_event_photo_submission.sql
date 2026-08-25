-- Public event-photo submission (event-photos.html). Gating: an explicit
-- admin/Telegram toggle (settings.event_photo_submission_enabled = 'true'
-- or 'false') always wins when set; if unset, falls back to the target
-- event's own date_from/date_to window. Registration reuses the real
-- customer_sessions login (no separate lightweight auth) — p_token must be
-- a valid, unexpired session, same trust level as submit_review/get_my_orders.
--
-- Caption/Instagram-handle metadata + the Instagram carousel-batching state
-- (posted_to_instagram/instagram_post_id) can't live in popups.photos — that
-- stays a plain array of URL strings, the format admin.html's event editor
-- already reads/writes, so it can't be repurposed into an array of objects
-- without breaking existing events. This table is the richer record; the
-- plain URL is still mirrored into popups.photos so the existing gallery
-- display keeps working unchanged.
CREATE TABLE IF NOT EXISTS event_photo_submissions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id             uuid REFERENCES popups(id),
  customer_id          uuid REFERENCES customers(id),
  photo_url            text NOT NULL,
  caption              text,
  instagram_handle     text,
  posted_to_instagram  boolean NOT NULL DEFAULT false,
  instagram_post_id    text,
  created_at           timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_event_photo_submissions_unposted ON event_photo_submissions (event_id, posted_to_instagram);
ALTER TABLE event_photo_submissions ENABLE ROW LEVEL SECURITY;
-- no policies — service_role (the event-photo-submit Edge Function) only

-- Deliberately scoped to append-only: this RPC can only ever add one row for
-- one event, nothing else on popups (title/location/status) is reachable
-- through it, even though popups' table-level RLS is otherwise fully open
-- to anon. Called from the event-photo-submit Edge Function (service_role),
-- not directly from the browser, so it can also report back the event's
-- current unposted-photo count for the Instagram carousel batching decision.
CREATE OR REPLACE FUNCTION add_event_photo(p_token text, p_event_id uuid, p_photo_url text, p_caption text DEFAULT NULL, p_instagram_handle text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wa text;
  v_customer_id uuid;
  v_manual text;
  v_event popups;
  v_unposted_count int;
BEGIN
  SELECT customer_id, wa INTO v_customer_id, v_wa FROM customer_sessions WHERE token = p_token AND expires_at > now();
  IF v_wa IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'not_logged_in'); END IF;

  SELECT * INTO v_event FROM popups WHERE id = p_event_id;
  IF v_event IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'event_not_found'); END IF;

  SELECT value INTO v_manual FROM settings WHERE key = 'event_photo_submission_enabled';
  IF v_manual = 'false' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'submissions_closed');
  ELSIF v_manual IS DISTINCT FROM 'true' THEN
    -- No explicit override: open only during the event's own date range.
    IF v_event.date_from IS NULL OR CURRENT_DATE < v_event.date_from OR CURRENT_DATE > v_event.date_to THEN
      RETURN jsonb_build_object('ok', false, 'error', 'submissions_closed');
    END IF;
  END IF;

  UPDATE popups SET photos = coalesce(photos, '[]'::jsonb) || jsonb_build_array(p_photo_url) WHERE id = p_event_id;

  INSERT INTO event_photo_submissions (event_id, customer_id, photo_url, caption, instagram_handle)
    VALUES (p_event_id, v_customer_id, p_photo_url, p_caption, p_instagram_handle);

  SELECT count(*) INTO v_unposted_count FROM event_photo_submissions WHERE event_id = p_event_id AND posted_to_instagram = false;

  RETURN jsonb_build_object('ok', true, 'unposted_count', v_unposted_count);
END;
$$;
GRANT EXECUTE ON FUNCTION add_event_photo(text, uuid, text, text, text) TO anon, authenticated;

-- Returns up to 4 oldest unposted photos for an event, for the Instagram
-- carousel Edge Function to build a post from — never more than the batch
-- size, so a slow burst of submissions can't accidentally build an
-- oversized carousel (Instagram's own cap is 10, but 4 is this project's
-- chosen batch size).
CREATE OR REPLACE FUNCTION get_unposted_event_photos(p_event_id uuid, p_limit int DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Joins customers for a name fallback — a submitter who didn't give an
  -- Instagram handle still gets credited by name rather than silently
  -- dropped from the caption.
  RETURN (
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'photo_url', t.photo_url, 'caption', t.caption, 'instagram_handle', t.instagram_handle, 'customer_name', c.name) ORDER BY t.created_at), '[]'::jsonb)
    FROM (SELECT * FROM event_photo_submissions WHERE event_id = p_event_id AND posted_to_instagram = false ORDER BY created_at LIMIT p_limit) t
    LEFT JOIN customers c ON c.id = t.customer_id
  );
END;
$$;
-- service_role only — called from event-photo-submit, not the browser

-- Marks a specific batch of submissions posted, after a successful
-- Instagram publish. service_role only.
CREATE OR REPLACE FUNCTION mark_event_photos_posted(p_ids uuid[], p_instagram_post_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE event_photo_submissions SET posted_to_instagram = true, instagram_post_id = p_instagram_post_id WHERE id = ANY(p_ids);
END;
$$;

-- Lists events open for public submission right now (manual toggle or date
-- range), for the picker on event-photos.html. Read-only, no PII.
CREATE OR REPLACE FUNCTION list_open_photo_events()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_manual text;
BEGIN
  SELECT value INTO v_manual FROM settings WHERE key = 'event_photo_submission_enabled';
  IF v_manual = 'false' THEN RETURN '[]'::jsonb; END IF;

  IF v_manual = 'true' THEN
    RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'location', location) ORDER BY date_from), '[]'::jsonb)
            FROM popups WHERE status <> 'past');
  END IF;

  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'location', location) ORDER BY date_from), '[]'::jsonb)
          FROM popups WHERE date_from IS NOT NULL AND CURRENT_DATE BETWEEN date_from AND date_to);
END;
$$;
GRANT EXECUTE ON FUNCTION list_open_photo_events() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
