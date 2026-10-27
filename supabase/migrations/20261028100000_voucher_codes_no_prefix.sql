-- Event-registration vouchers are now minted as a bare 6-character code
-- (e.g. A3F92B), no MSH- prefix. Same as manual vouchers (DIWALI200), so
-- staff type or scan one code the same way for every voucher. Existing
-- MSH- codes stay valid — only newly minted codes change.
-- Body is identical to 20261027220000's register_event_visitor except the
-- code generation line.

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
    new_code := upper(substr(md5(random()::text), 1, 6));
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
