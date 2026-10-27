-- Hardening for the anon-callable register_event_visitor, from the
-- 2026-10-28 security audit. NOT applied automatically — review first.
--
--  * p_email gets DEFAULT NULL so callers may omit it (previously omitting it
--    made PostgREST return 404/PGRST202; register.html now sends '' as a
--    stop-gap, which keeps working after this migration).
--  * Never UPDATE an existing customers row from this anon path: an attacker
--    could overwrite a pre-staged unverified account's wa/email/name. A row
--    is only inserted when neither the wa nor the email matches one.
--  * Server-side limits: name <= 80 chars, WhatsApp 10-15 digits, Instagram
--    handle must match ^@?[A-Za-z0-9._]{1,30}$ and is stored as '@handle'.
-- Otherwise identical to 20261028300000's body.

DROP FUNCTION IF EXISTS register_event_visitor(uuid, text, text, text, text);
CREATE OR REPLACE FUNCTION register_event_visitor(
  p_event_id uuid, p_name text, p_wa text, p_email text DEFAULT NULL, p_instagram text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  ev voucher_events;
  wa_digits text := regexp_replace(coalesce(p_wa, ''), '[^0-9]', '', 'g');
  email_clean text := nullif(trim(coalesce(p_email, '')), '');
  ig_clean text := nullif(trim(coalesce(p_instagram, '')), '');
  existing coupons;
  existing_cust customers;
  new_code text;
  c coupons;
BEGIN
  SELECT * INTO ev FROM voucher_events WHERE id = p_event_id AND active;
  IF ev IS NULL THEN
    RETURN jsonb_build_object('error', 'This event link is no longer active.');
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' OR length(trim(p_name)) > 80
     OR length(wa_digits) < 10 OR length(wa_digits) > 15 THEN
    RETURN jsonb_build_object('error', 'Enter a valid name and WhatsApp number.');
  END IF;
  IF email_clean IS NOT NULL AND (length(email_clean) > 254 OR email_clean NOT LIKE '%@%.%') THEN
    RETURN jsonb_build_object('error', 'Enter a valid email address.');
  END IF;
  IF ev.requires_instagram AND ig_clean IS NULL THEN
    RETURN jsonb_build_object('error', 'Enter your Instagram handle.');
  END IF;
  IF ig_clean IS NOT NULL THEN
    IF ig_clean !~ '^@?[A-Za-z0-9._]{1,30}$' THEN
      RETURN jsonb_build_object('error', 'Enter a valid Instagram handle.');
    END IF;
    ig_clean := '@' || ltrim(ig_clean, '@');
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

  IF email_clean IS NOT NULL THEN
    SELECT * INTO existing_cust FROM customers WHERE wa = wa_digits OR email = email_clean LIMIT 1;
    IF existing_cust IS NULL THEN
      INSERT INTO customers (wa, email, name, password_hash)
        VALUES (wa_digits, email_clean, trim(p_name), crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')));
    END IF;
  END IF;

  LOOP
    new_code := upper(substr(md5(random()::text), 1, 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM coupons WHERE code = new_code);
  END LOOP;

  INSERT INTO coupons (
    code, customer_name, customer_wa, customer_email, instagram_handle, discount_type, discount_value,
    region, valid_from, valid_until, source, event_id
  ) VALUES (
    new_code, trim(p_name), wa_digits, email_clean, ig_clean, ev.discount_type, ev.discount_value,
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
