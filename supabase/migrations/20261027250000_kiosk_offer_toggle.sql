-- Per-event on/off for the kiosk's discount picker. Default ON, so every
-- existing event keeps showing exactly as before until someone switches it off.
-- The kiosk's Create event/promotion screen lists events and flips this flag.

ALTER TABLE voucher_events ADD COLUMN IF NOT EXISTS kiosk_offer_enabled boolean NOT NULL DEFAULT true;

-- Changing the RETURNS TABLE shape — drop first (same as the popup-link migration).
DROP FUNCTION IF EXISTS admin_list_voucher_events();
CREATE OR REPLACE FUNCTION admin_list_voucher_events()
RETURNS TABLE (
  id uuid, title text, kind text, region text, discount_type text,
  discount_value numeric, valid_days int, active boolean, created_by text,
  created_at timestamptz, registrant_count bigint, requires_instagram boolean,
  popup_id uuid, popup_title text, popup_photo text, kiosk_offer_enabled boolean
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT ve.id, ve.title, ve.kind, ve.region, ve.discount_type, ve.discount_value,
         ve.valid_days, ve.active, ve.created_by, ve.created_at,
         (SELECT count(*) FROM coupons c WHERE c.event_id = ve.id), ve.requires_instagram,
         ve.popup_id, p.title, (p.photos->>0), ve.kiosk_offer_enabled
  FROM voucher_events ve
  LEFT JOIN popups p ON p.id = ve.popup_id
  ORDER BY ve.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION admin_list_voucher_events() TO anon, authenticated;

CREATE OR REPLACE FUNCTION admin_set_voucher_event_kiosk_offer(p_id uuid, p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM require_admin_session();
  UPDATE voucher_events SET kiosk_offer_enabled = p_enabled WHERE id = p_id;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION admin_set_voucher_event_kiosk_offer(uuid, boolean) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
