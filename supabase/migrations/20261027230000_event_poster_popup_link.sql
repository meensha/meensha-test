-- Lets a voucher_events row (admin.html's Events & Promotions) link to an
-- existing popups row (the storefront's Pop-Up Events, with its own photo
-- gallery) so the poster generator can use that event's actual uploaded
-- photo as its background, instead of requiring separate static template
-- PNGs (the original plan's design, abandoned — no template PNGs were ever
-- supplied, and reusing the event's own real photo is simpler and correct).

ALTER TABLE voucher_events ADD COLUMN IF NOT EXISTS popup_id uuid REFERENCES popups(id);

DROP FUNCTION IF EXISTS admin_create_voucher_event(text, text, text, numeric, int, text, text, boolean);
CREATE OR REPLACE FUNCTION admin_create_voucher_event(
  p_title text, p_region text, p_discount_type text, p_discount_value numeric,
  p_valid_days int, p_created_by text, p_kind text DEFAULT 'event',
  p_requires_instagram boolean DEFAULT false, p_popup_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE ev voucher_events;
BEGIN
  INSERT INTO voucher_events (title, region, discount_type, discount_value, valid_days, created_by, kind, requires_instagram, popup_id)
  VALUES (p_title, p_region, p_discount_type, p_discount_value, COALESCE(p_valid_days, 7), p_created_by, COALESCE(p_kind, 'event'), COALESCE(p_requires_instagram, false), p_popup_id)
  RETURNING * INTO ev;
  RETURN jsonb_build_object('id', ev.id, 'title', ev.title);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_create_voucher_event(text, text, text, numeric, int, text, text, boolean, uuid) TO anon, authenticated;

-- Changing the RETURNS TABLE shape again — drop first (see the instagram
-- migration's note on why CREATE OR REPLACE can't do this alone).
DROP FUNCTION IF EXISTS admin_list_voucher_events();
CREATE OR REPLACE FUNCTION admin_list_voucher_events()
RETURNS TABLE (
  id uuid, title text, kind text, region text, discount_type text,
  discount_value numeric, valid_days int, active boolean, created_by text,
  created_at timestamptz, registrant_count bigint, requires_instagram boolean,
  popup_id uuid, popup_title text, popup_photo text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT ve.id, ve.title, ve.kind, ve.region, ve.discount_type, ve.discount_value,
         ve.valid_days, ve.active, ve.created_by, ve.created_at,
         (SELECT count(*) FROM coupons c WHERE c.event_id = ve.id), ve.requires_instagram,
         ve.popup_id, p.title, (p.photos->>0)
  FROM voucher_events ve
  LEFT JOIN popups p ON p.id = ve.popup_id
  ORDER BY ve.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION admin_list_voucher_events() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
