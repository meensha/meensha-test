-- Events & promotions v2 (see ~/.claude/plans/stateless-nibbling-scone.md).
-- Adds a kind distinction (event vs promotion) to voucher_events, email
-- capture on coupons/registration, and admin list/export RPCs for a
-- persistent Events & Promotions register in admin.html.

ALTER TABLE voucher_events ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'event'
  CHECK (kind IN ('event','promotion'));

ALTER TABLE coupons ADD COLUMN IF NOT EXISTS customer_email text;

-- Admin register view — mirrors admin_list_coupons's pattern, adds a live
-- registrant count per event/promotion.
CREATE OR REPLACE FUNCTION admin_list_voucher_events()
RETURNS TABLE (
  id uuid, title text, kind text, region text, discount_type text,
  discount_value numeric, valid_days int, active boolean, created_by text,
  created_at timestamptz, registrant_count bigint
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT ve.id, ve.title, ve.kind, ve.region, ve.discount_type, ve.discount_value,
         ve.valid_days, ve.active, ve.created_by, ve.created_at,
         (SELECT count(*) FROM coupons c WHERE c.event_id = ve.id)
  FROM voucher_events ve
  ORDER BY ve.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION admin_list_voucher_events() TO anon, authenticated;

CREATE OR REPLACE FUNCTION admin_set_voucher_event_active(p_id uuid, p_active boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE voucher_events SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$$;
GRANT EXECUTE ON FUNCTION admin_set_voucher_event_active(uuid, boolean) TO anon, authenticated;

-- Registrant export for an event/promotion — the audience list for WhatsApp
-- Business bulk upload / email tools (no WhatsApp broadcast built here).
CREATE OR REPLACE FUNCTION admin_export_event_registrants(p_event_id uuid)
RETURNS TABLE (
  customer_name text, customer_wa text, customer_email text,
  code text, used boolean, used_at timestamptz, created_at timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT c.customer_name, c.customer_wa, c.customer_email, c.code, c.used, c.used_at, c.created_at
  FROM coupons c WHERE c.event_id = p_event_id ORDER BY c.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION admin_export_event_registrants(uuid) TO anon, authenticated;

-- Extend registration to require an email and (a) store it on the minted
-- coupon, (b) pre-stage a customers row so the account exists once login
-- ships. Email is required (not just stored) because customers.email is
-- NOT NULL — a visitor who registers for an event now always gets an
-- account. Password is a securely random, never-shown value; the visitor
-- sets a real one later via the existing request_password_reset /
-- verify_password_reset flow (email-OTP, already built, no new UI needed
-- here) — this RPC never emails anything itself, it just creates the row.
-- If a *verified* account already exists under this wa/email, we don't
-- touch it (avoids a stray unverified pre-stage clobbering a real account);
-- if an unverified pre-stage already exists, we just refresh name/email —
-- consistent with start_customer_signup's own "unverified = overwritable"
-- rule in supabase/migrations/20261015110000_customer_auth.sql.
CREATE OR REPLACE FUNCTION register_event_visitor(p_event_id uuid, p_name text, p_wa text, p_email text)
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
  -- a verified existing account is left untouched — the coupon still mints below

  LOOP
    new_code := 'MSH-' || upper(substr(md5(random()::text), 1, 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM coupons WHERE code = new_code);
  END LOOP;

  INSERT INTO coupons (
    code, customer_name, customer_wa, customer_email, discount_type, discount_value,
    region, valid_from, valid_until, source, event_id
  ) VALUES (
    new_code, trim(p_name), wa_digits, nullif(trim(coalesce(p_email,'')), ''), ev.discount_type, ev.discount_value,
    ev.region, current_date, current_date + ev.valid_days, 'event_registration', p_event_id
  )
  RETURNING * INTO c;

  RETURN jsonb_build_object(
    'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;
GRANT EXECUTE ON FUNCTION register_event_visitor(uuid, text, text, text) TO anon, authenticated;

-- admin_create_voucher_event extended to accept kind (prefill default handled client-side).
CREATE OR REPLACE FUNCTION admin_create_voucher_event(
  p_title text, p_region text, p_discount_type text, p_discount_value numeric,
  p_valid_days int, p_created_by text, p_kind text DEFAULT 'event'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE ev voucher_events;
BEGIN
  INSERT INTO voucher_events (title, region, discount_type, discount_value, valid_days, created_by, kind)
  VALUES (p_title, p_region, p_discount_type, p_discount_value, COALESCE(p_valid_days, 7), p_created_by, COALESCE(p_kind, 'event'))
  RETURNING * INTO ev;
  RETURN jsonb_build_object('id', ev.id, 'title', ev.title);
END;
$$;
GRANT EXECUTE ON FUNCTION admin_create_voucher_event(text, text, text, numeric, int, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
