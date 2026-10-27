-- Pop-Up Event prep checklist + post-event notes.
--
-- Revision note: this migration has never been applied (not yet shipped),
-- so it's rewritten in place rather than chained — no ALTER/rename dance.
-- Original design had one fixed, hardcoded 14-item checklist. Per a scope
-- change from the project owner, the checklist is now editable structure:
--   - checklist_template_phases / checklist_template_items: the master
--     template admin.html's new "Checklist Template" editor manages
--     (add/rename/delete/reorder phases and items).
--   - popup_checklist_phases / popup_checklist_items: a per-popup SNAPSHOT,
--     copied from the template at popup-creation time by the
--     trg_create_popup_checklist trigger. Editing the template later does
--     NOT retroactively change an already-created event's checklist — each
--     event's checklist is its own copy from then on.
--
-- Both kiosk.html and admin.html read/write the same snapshot rows through
-- the RPCs below — single source of truth, no independently derived state.
-- Neither the template tables nor the snapshot tables get a REST-exposed
-- RLS policy or a GRANT to anon/authenticated — all access is through the
-- SECURITY DEFINER RPCs below, each of which calls require_admin_session()
-- first. With no table grant at all, there is no direct-REST surface to
-- lock down in the first place.

CREATE TABLE IF NOT EXISTS checklist_template_phases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  order_index int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE checklist_template_phases ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS checklist_template_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phase_id uuid NOT NULL REFERENCES checklist_template_phases(id) ON DELETE CASCADE,
  title text NOT NULL,
  order_index int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE checklist_template_items ENABLE ROW LEVEL SECURITY;

-- Seed: the original 4 phases / 14 items, so the owner isn't starting from
-- a blank template. From here on this is just normal editable data.
DO $$
DECLARE v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM checklist_template_phases) THEN
    INSERT INTO checklist_template_phases(title, order_index) VALUES ('Book Stall', 1) RETURNING id INTO v_p1;
    INSERT INTO checklist_template_phases(title, order_index) VALUES ('Publicity', 2) RETURNING id INTO v_p2;
    INSERT INTO checklist_template_phases(title, order_index) VALUES ('Inventory check', 3) RETURNING id INTO v_p3;
    INSERT INTO checklist_template_phases(title, order_index) VALUES ('Final coordination', 4) RETURNING id INTO v_p4;

    INSERT INTO checklist_template_items(phase_id, title, order_index) VALUES
      (v_p1, 'Confirm exact space/design', 1),
      (v_p1, 'Confirm facilities (shed, electrical, etc.)', 2),
      (v_p2, 'Generate poster', 1),
      (v_p2, 'Posted on Instagram', 2),
      (v_p2, 'Posted on Facebook', 3),
      (v_p2, 'Posted on WhatsApp', 4),
      (v_p3, 'Stock check', 1),
      (v_p3, 'Pricing check', 2),
      (v_p3, 'Generate registration QR poster', 3),
      (v_p3, 'Reviewed notes from previous event', 4),
      (v_p4, 'Packed up', 1),
      (v_p4, 'Transport arranged', 2),
      (v_p4, 'Kiosk app working', 3),
      (v_p4, 'Printed stock sheet', 4);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS popup_checklist_phases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  popup_id uuid NOT NULL REFERENCES popups(id) ON DELETE CASCADE,
  title text NOT NULL,
  order_index int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE popup_checklist_phases ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS popup_checklist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  popup_id uuid NOT NULL REFERENCES popups(id) ON DELETE CASCADE,
  phase_id uuid NOT NULL REFERENCES popup_checklist_phases(id) ON DELETE CASCADE,
  title text NOT NULL,
  order_index int NOT NULL,
  checked boolean NOT NULL DEFAULT false,
  checked_by uuid REFERENCES users(id),
  checked_by_name text,
  checked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE popup_checklist_items ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS popup_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  popup_id uuid NOT NULL REFERENCES popups(id) ON DELETE CASCADE,
  note text NOT NULL,
  written_by uuid REFERENCES users(id),
  written_by_name text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE popup_notes ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS popup_note_summaries (
  popup_id uuid PRIMARY KEY REFERENCES popups(id) ON DELETE CASCADE,
  summary text NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  generated_by uuid REFERENCES users(id)
);
ALTER TABLE popup_note_summaries ENABLE ROW LEVEL SECURITY;

-- Trigger: every new popup gets a snapshot copy of the CURRENT template.
-- SECURITY DEFINER is required: the snapshot tables grant no privileges to
-- anon/authenticated at all, so an admin.html REST INSERT into popups
-- (which runs as anon) would otherwise hit "permission denied" on this
-- trigger's own INSERTs and roll back the whole popup insert. Running as
-- the function owner (postgres, which owns these tables) bypasses that,
-- same as every other SECURITY DEFINER function below.
CREATE OR REPLACE FUNCTION public.trg_create_popup_checklist()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_phase_id uuid;
BEGIN
  FOR r IN SELECT id, title, order_index FROM checklist_template_phases ORDER BY order_index LOOP
    INSERT INTO popup_checklist_phases(popup_id, title, order_index)
      VALUES (NEW.id, r.title, r.order_index) RETURNING id INTO v_phase_id;
    INSERT INTO popup_checklist_items(popup_id, phase_id, title, order_index)
      SELECT NEW.id, v_phase_id, ti.title, ti.order_index
      FROM checklist_template_items ti WHERE ti.phase_id = r.id ORDER BY ti.order_index;
  END LOOP;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS popup_checklist_autocreate ON popups;
CREATE TRIGGER popup_checklist_autocreate AFTER INSERT ON popups
  FOR EACH ROW EXECUTE FUNCTION public.trg_create_popup_checklist();

-- Backfill: give every popup that already existed before this migration
-- the same snapshot (the trigger above only fires for rows inserted after
-- it's created).
DO $$
DECLARE p record; r record; v_phase_id uuid;
BEGIN
  FOR p IN SELECT id FROM popups WHERE id NOT IN (SELECT DISTINCT popup_id FROM popup_checklist_phases) LOOP
    FOR r IN SELECT id, title, order_index FROM checklist_template_phases ORDER BY order_index LOOP
      INSERT INTO popup_checklist_phases(popup_id, title, order_index)
        VALUES (p.id, r.title, r.order_index) RETURNING id INTO v_phase_id;
      INSERT INTO popup_checklist_items(popup_id, phase_id, title, order_index)
        SELECT p.id, v_phase_id, ti.title, ti.order_index
        FROM checklist_template_items ti WHERE ti.phase_id = r.id ORDER BY ti.order_index;
    END LOOP;
  END LOOP;
END $$;

-- ── Per-popup checklist RPCs (kiosk.html + admin.html, shared) ───────────

-- Read one event's checklist, phase + item titles/order already resolved
-- (the client doesn't need a second call to know phase names).
CREATE OR REPLACE FUNCTION public.popup_checklist_list(p_popup_id uuid)
 RETURNS TABLE(item_id uuid, phase_id uuid, phase_title text, phase_order int, item_title text, item_order int, checked boolean, checked_by_name text, checked_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT i.id, ph.id, ph.title, ph.order_index, i.title, i.order_index, i.checked, i.checked_by_name, i.checked_at
    FROM popup_checklist_items i
    JOIN popup_checklist_phases ph ON ph.id = i.phase_id
    WHERE i.popup_id = p_popup_id
    ORDER BY ph.order_index, i.order_index;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_checklist_list(uuid) TO anon, authenticated;

-- Check/uncheck one item, addressed by its snapshot row id (items are no
-- longer a fixed key set now that the template is editable). Any logged-in
-- role may toggle any item (confirmed decision — no per-item role gating).
-- checked_by/checked_by_name/checked_at come from the resolved session,
-- never the client payload.
CREATE OR REPLACE FUNCTION public.popup_checklist_toggle(p_popup_id uuid, p_item_id uuid, p_checked boolean)
 RETURNS TABLE(item_id uuid, phase_id uuid, phase_title text, phase_order int, item_title text, item_order int, checked boolean, checked_by_name text, checked_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  UPDATE popup_checklist_items i
     SET checked = p_checked,
         checked_by = CASE WHEN p_checked THEN me.id ELSE NULL END,
         checked_by_name = CASE WHEN p_checked THEN me.display_name ELSE NULL END,
         checked_at = CASE WHEN p_checked THEN now() ELSE NULL END
   WHERE i.id = p_item_id AND i.popup_id = p_popup_id;
  RETURN QUERY
    SELECT i.id, ph.id, ph.title, ph.order_index, i.title, i.order_index, i.checked, i.checked_by_name, i.checked_at
    FROM popup_checklist_items i
    JOIN popup_checklist_phases ph ON ph.id = i.phase_id
    WHERE i.id = p_item_id AND i.popup_id = p_popup_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_checklist_toggle(uuid, uuid, boolean) TO anon, authenticated;

-- Drives the kiosk nag banner: one row per upcoming/live popup that still
-- has at least one unchecked item, with how many are open. Unchanged
-- signature/shape from the original design.
CREATE OR REPLACE FUNCTION public.popup_checklist_open_summary()
 RETURNS TABLE(popup_id uuid, title text, status text, open_count int)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT p.id, p.title, p.status, count(*)::int
    FROM popups p
    JOIN popup_checklist_items i ON i.popup_id = p.id AND i.checked = false
    WHERE p.status IN ('upcoming','live')
    GROUP BY p.id, p.title, p.status
    ORDER BY p.date_from;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_checklist_open_summary() TO anon, authenticated;

-- Surfaces the most recently past popup's AI summary (if one was ever
-- generated) for the "Reviewed notes from previous event" checklist item.
-- Unchanged from the original design.
CREATE OR REPLACE FUNCTION public.popup_previous_summary(p_popup_id uuid)
 RETURNS TABLE(title text, summary text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_date_from date;
BEGIN
  PERFORM require_admin_session();
  SELECT date_from INTO v_date_from FROM popups WHERE id = p_popup_id;
  -- A bad/nonexistent p_popup_id must return nothing, not fall through to
  -- "no date filter" (which would otherwise silently return the globally
  -- most recent past event's summary — wrong, and misleading in the UI).
  IF NOT FOUND THEN RETURN; END IF;
  RETURN QUERY
    SELECT p.title, s.summary
    FROM popups p
    LEFT JOIN popup_note_summaries s ON s.popup_id = p.id
    WHERE p.status = 'past' AND p.id <> p_popup_id
      AND (v_date_from IS NULL OR p.date_from < v_date_from)
    ORDER BY p.date_from DESC
    LIMIT 1;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_previous_summary(uuid) TO anon, authenticated;

-- Kiosk-side event creation. Unchanged signature — the checklist-snapshot
-- trigger above fires on this INSERT same as it does for admin's saveEv().
CREATE OR REPLACE FUNCTION public.popup_create_from_kiosk(
  p_title text, p_dates text, p_date_from date, p_date_to date, p_timings text,
  p_location text, p_location_url text, p_writeup text, p_status text, p_photos jsonb
) RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid;
BEGIN
  PERFORM require_admin_session();
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'title_required'; END IF;
  IF p_location IS NULL OR btrim(p_location) = '' THEN RAISE EXCEPTION 'location_required'; END IF;
  IF p_date_from IS NULL OR p_date_to IS NULL THEN RAISE EXCEPTION 'dates_required'; END IF;
  -- This RPC can put a popup straight onto the public-facing site, so
  -- p_status is constrained to the same enum admin.html's EV-ST <select>
  -- offers, and p_photos must be a plain array of http(s) URLs (what
  -- kiosk.html's own uploadFile() always produces) — not arbitrary strings.
  IF p_status IS NOT NULL AND p_status NOT IN ('upcoming','live','past') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;
  IF p_photos IS NOT NULL THEN
    IF jsonb_typeof(p_photos) <> 'array' THEN RAISE EXCEPTION 'photos_must_be_array'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_photos) AS u WHERE u !~ '^https?://') THEN
      RAISE EXCEPTION 'invalid_photo_url';
    END IF;
  END IF;
  INSERT INTO popups(title, dates, date_from, date_to, timings, location, location_url, writeup, status, photos)
    VALUES (p_title, p_dates, p_date_from, p_date_to, p_timings, p_location, p_location_url, p_writeup,
            coalesce(p_status,'upcoming'), coalesce(p_photos,'[]'::jsonb))
    RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_create_from_kiosk(text,text,date,date,text,text,text,text,text,jsonb) TO anon, authenticated;

-- ── Post-event notes (unchanged from the original design) ────────────────

CREATE OR REPLACE FUNCTION public.popup_notes_add(p_popup_id uuid, p_note text)
 RETURNS TABLE(id uuid, note text, written_by_name text, created_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users; v_id uuid;
BEGIN
  me := require_admin_session();
  IF p_note IS NULL OR btrim(p_note) = '' THEN RAISE EXCEPTION 'note_required'; END IF;
  INSERT INTO popup_notes(popup_id, note, written_by, written_by_name)
    VALUES (p_popup_id, p_note, me.id, me.display_name)
    RETURNING popup_notes.id INTO v_id;
  RETURN QUERY SELECT n.id, n.note, n.written_by_name, n.created_at FROM popup_notes n WHERE n.id = v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_notes_add(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.popup_notes_list(p_popup_id uuid)
 RETURNS TABLE(id uuid, note text, written_by_name text, created_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT n.id, n.note, n.written_by_name, n.created_at
    FROM popup_notes n WHERE n.popup_id = p_popup_id ORDER BY n.created_at DESC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_notes_list(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.popup_notes_save_summary(p_popup_id uuid, p_summary text)
 RETURNS TABLE(popup_id uuid, summary text, generated_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  INSERT INTO popup_note_summaries(popup_id, summary, generated_at, generated_by)
    VALUES (p_popup_id, p_summary, now(), me.id)
    ON CONFLICT (popup_id) DO UPDATE
      SET summary = excluded.summary, generated_at = excluded.generated_at, generated_by = excluded.generated_by;
  RETURN QUERY SELECT s.popup_id, s.summary, s.generated_at FROM popup_note_summaries s WHERE s.popup_id = p_popup_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_notes_save_summary(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.popup_note_summaries_list()
 RETURNS TABLE(popup_id uuid, title text, date_to date, summary text, generated_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT p.id, p.title, p.date_to, s.summary, s.generated_at
    FROM popup_note_summaries s JOIN popups p ON p.id = s.popup_id
    ORDER BY p.date_to DESC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.popup_note_summaries_list() TO anon, authenticated;

-- ── Checklist TEMPLATE editor RPCs (admin.html only; kiosk.html never
--    touches these) ───────────────────────────────────────────────────

-- Flat list, phase + item together (client groups by phase_id). Ordered
-- so the editor can render top-to-bottom without a second sort pass.
CREATE OR REPLACE FUNCTION public.admin_checklist_template_list()
 RETURNS TABLE(phase_id uuid, phase_title text, phase_order int, item_id uuid, item_title text, item_order int)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT ph.id, ph.title, ph.order_index, ti.id, ti.title, ti.order_index
    FROM checklist_template_phases ph
    LEFT JOIN checklist_template_items ti ON ti.phase_id = ph.id
    ORDER BY ph.order_index, ti.order_index;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_list() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_add_phase(p_title text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid; v_next int;
BEGIN
  PERFORM require_admin_session();
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'title_required'; END IF;
  SELECT coalesce(max(order_index), 0) + 1 INTO v_next FROM checklist_template_phases;
  INSERT INTO checklist_template_phases(title, order_index) VALUES (p_title, v_next) RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_add_phase(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_add_item(p_phase_id uuid, p_title text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_id uuid; v_next int;
BEGIN
  PERFORM require_admin_session();
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'title_required'; END IF;
  SELECT coalesce(max(order_index), 0) + 1 INTO v_next FROM checklist_template_items WHERE phase_id = p_phase_id;
  INSERT INTO checklist_template_items(phase_id, title, order_index) VALUES (p_phase_id, p_title, v_next) RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_add_item(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_rename_phase(p_phase_id uuid, p_title text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'title_required'; END IF;
  UPDATE checklist_template_phases SET title = p_title WHERE id = p_phase_id;
  RETURN FOUND;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_rename_phase(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_rename_item(p_item_id uuid, p_title text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'title_required'; END IF;
  UPDATE checklist_template_items SET title = p_title WHERE id = p_item_id;
  RETURN FOUND;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_rename_item(uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_delete_phase(p_phase_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  DELETE FROM checklist_template_phases WHERE id = p_phase_id; -- cascades to its items
  RETURN FOUND;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_delete_phase(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_checklist_template_delete_item(p_item_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  DELETE FROM checklist_template_items WHERE id = p_item_id;
  RETURN FOUND;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_checklist_template_delete_item(uuid) TO anon, authenticated;

-- Phases reorder among phases; items reorder within their own phase only
-- (no cross-phase drag). Each takes the new order as an array of ids —
-- position in the array becomes the new order_index.
CREATE OR REPLACE FUNCTION public.admin_reorder_checklist_phases(p_phase_ids uuid[])
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE checklist_template_phases t SET order_index = o.ord
  FROM (SELECT id, row_number() OVER () AS ord FROM unnest(p_phase_ids) AS id) o
  WHERE t.id = o.id;
  RETURN true;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_reorder_checklist_phases(uuid[]) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_reorder_checklist_items(p_phase_id uuid, p_item_ids uuid[])
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE checklist_template_items t SET order_index = o.ord
  FROM (SELECT id, row_number() OVER () AS ord FROM unnest(p_item_ids) AS id) o
  WHERE t.id = o.id AND t.phase_id = p_phase_id;
  RETURN true;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_reorder_checklist_items(uuid, uuid[]) TO anon, authenticated;
