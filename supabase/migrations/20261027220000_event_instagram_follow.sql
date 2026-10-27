-- Optional "follow us on Instagram" step on event/promotion registration.
-- No Instagram Business API access exists yet (pending Meta App Review,
-- see TODO.md), so this is an honor-system gate on register.html, not a
-- verified check: the visitor taps a Follow link, then types their handle
-- so staff can glance at it and manually confirm the follow at redemption
-- (the owner's own call on how to handle verification for this feature).

ALTER TABLE voucher_events ADD COLUMN IF NOT EXISTS requires_instagram boolean NOT NULL DEFAULT false;
ALTER TABLE coupons ADD COLUMN IF NOT EXISTS instagram_handle text;
-- admin_list_coupons() is `SELECT * FROM coupons`, so instagram_handle is
-- already exposed there with no RPC change needed. admin_list_voucher_events()
-- selects explicit columns though, so that one needs extending below.

-- Changing the RETURNS TABLE shape — Postgres won't let CREATE OR REPLACE
-- alter an existing function's return type, so drop first.
DROP FUNCTION IF EXISTS admin_list_voucher_events();
CREATE OR REPLACE FUNCTION admin_list_voucher_events()
RETURNS TABLE (
  id uuid, title text, kind text, region text, discount_type text,
  discount_value numeric, valid_days int, active boolean, created_by text,
  created_at timestamptz, registrant_count bigint, requires_instagram boolean
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT ve.id, ve.title, ve.kind, ve.region, ve.discount_type, ve.discount_value,
         ve.valid_days, ve.active, ve.created_by, ve.created_at,
         (SELECT count(*) FROM coupons c WHERE c.event_id = ve.id), ve.requires_instagram
  FROM voucher_events ve
  ORDER BY ve.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION admin_list_voucher_events() TO anon, authenticated;

CREATE OR REPLACE FUNCTION get_voucher_event(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN id IS NULL THEN NULL ELSE jsonb_build_object(
    'id', id, 'title', title, 'region', region,
    'discount_type', discount_type, 'discount_value', discount_value, 'active', active,
    'requires_instagram', requires_instagram
  ) END
  FROM voucher_events WHERE id = p_event_id;
$$;
GRANT EXECUTE ON FUNCTION get_voucher_event(uuid) TO anon, authenticated;

-- Changing the parameter list, not just the body — drop the old overload
-- first so PostgREST never sees two matching signatures at once (it
-- resolves RPC calls by named parameters, and an old/new overload pair
-- that both satisfy a given request body is a real "function is not
-- unique" ambiguity, not just a cosmetic duplicate).
DROP FUNCTION IF EXISTS admin_create_voucher_event(text, text, text, numeric, int, text, text);
CREATE OR REPLACE FUNCTION admin_create_voucher_event(
  p_title text, p_region text, p_discount_type text, p_discount_value numeric,
  p_valid_days int, p_created_by text, p_kind text DEFAULT 'event',
  p_requires_instagram boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE ev voucher_events;
BEGIN
  INSERT INTO voucher_events (title, region, discount_type, discount_value, valid_days, created_by, kind, requires_instagram)
  VALUES (p_title, p_region, p_discount_type, p_discount_value, COALESCE(p_valid_days, 7), p_created_by, COALESCE(p_kind, 'event'), COALESCE(p_requires_instagram, false))
  RETURNING * INTO ev;
  RETURN jsonb_build_object('id', ev.id, 'title', ev.title);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_create_voucher_event(text, text, text, numeric, int, text, text, boolean) TO anon, authenticated;

-- Same overload-collision reasoning as admin_create_voucher_event above.
DROP FUNCTION IF EXISTS register_event_visitor(uuid, text, text, text);
CREATE OR REPLACE FUNCTION register_event_visitor(p_event_id uuid, p_name text, p_wa text, p_email text, p_instagram text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  ev voucher_events;
  wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
  existing coupons;
  existing_cust customers;
  new_code text;
  c coupons;
BEGIN
  SELECT * INTO ev FROM voucher_events WHERE id = p_event_id AND active;
  IF ev IS NULL THEN
    RETURN jsonb_build_object('error', 'This event link is no longer active.');
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' OR length(wa_digits) < 10 THEN
    RETURN jsonb_build_object('error', 'Enter a valid name and WhatsApp number.');
  END IF;
  IF p_email IS NULL OR trim(p_email) = '' OR p_email NOT LIKE '%@%.%' THEN
    RETURN jsonb_build_object('error', 'Enter a valid email address.');
  END IF;
  IF ev.requires_instagram AND (p_instagram IS NULL OR trim(p_instagram) = '') THEN
    RETURN jsonb_build_object('error', 'Enter your Instagram handle.');
  END IF;

  SELECT * INTO existing FROM coupons
    WHERE event_id = p_event_id
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'code', existing.code, 'discount_type', existing.discount_type,
      'discount_value', existing.discount_value, 'valid_until', existing.valid_until,
      'already_registered', true
    );
  END IF;

  SELECT * INTO existing_cust FROM customers WHERE wa = wa_digits OR email = trim(p_email);
  IF existing_cust IS NULL THEN
    INSERT INTO customers (wa, email, name, password_hash)
      VALUES (wa_digits, trim(p_email), trim(p_name), crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')));
  ELSIF existing_cust.email_verified_at IS NULL THEN
    UPDATE customers SET wa = wa_digits, email = trim(p_email), name = trim(p_name)
      WHERE id = existing_cust.id;
  END IF;

  LOOP
    new_code := 'MSH-' || upper(substr(md5(random()::text), 1, 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM coupons WHERE code = new_code);
  END LOOP;

  INSERT INTO coupons (
    code, customer_name, customer_wa, customer_email, instagram_handle, discount_type, discount_value,
    region, valid_from, valid_until, source, event_id
  ) VALUES (
    new_code, trim(p_name), wa_digits, nullif(trim(coalesce(p_email,'')), ''),
    nullif(trim(coalesce(p_instagram,'')), ''), ev.discount_type, ev.discount_value,
    ev.region, current_date, current_date + ev.valid_days, 'event_registration', p_event_id
  )
  RETURNING * INTO c;

  RETURN jsonb_build_object(
    'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;
GRANT EXECUTE ON FUNCTION register_event_visitor(uuid, text, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
