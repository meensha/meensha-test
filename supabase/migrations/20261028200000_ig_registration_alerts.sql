-- Recent event registrations that captured an Instagram handle, so the kiosk
-- can alert staff to check the follow. Session-guarded; read-only.

CREATE OR REPLACE FUNCTION admin_recent_ig_registrations(p_since timestamptz)
RETURNS TABLE (
  customer_name text, instagram_handle text, code text, event_title text, created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM require_admin_session();
  RETURN QUERY
    SELECT c.customer_name, c.instagram_handle, c.code, ve.title, c.created_at
    FROM coupons c
    LEFT JOIN voucher_events ve ON ve.id = c.event_id
    WHERE c.instagram_handle IS NOT NULL AND c.created_at >= p_since
    ORDER BY c.created_at DESC
    LIMIT 50;
END;
$$;
GRANT EXECUTE ON FUNCTION admin_recent_ig_registrations(timestamptz) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
