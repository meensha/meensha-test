-- The "scan for offer" flow (register.html -> register_event_visitor) only
-- ever wrote to `coupons`, never to `potential_customers` -- so every QR
-- registrant was invisible on the kiosk's Potential Customers screen (they
-- only showed up in admin-voucher.html's Coupons tab). This adds the same
-- potential_customers row the kiosk's "direct feed-in" flow
-- (save_potential_customer) already creates, so both lead sources land in
-- one follow-up list. Dedup by WhatsApp number's last 10 digits, same
-- comparison style register_event_visitor already uses against `coupons`,
-- since potential_customers has no unique constraint on `wa` to ON CONFLICT
-- against. Only fires on an actual new registration, not the
-- already-registered/rate-limit/validation-error early returns. Otherwise
-- identical to 20261028500000's register_event_visitor body.

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

  IF (SELECT count(*) FROM coupons
        WHERE event_id = p_event_id AND created_at > now() - interval '1 minute') >= 20 THEN
    RETURN jsonb_build_object('error', 'Lots of people are registering right now — please try again in a minute.');
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

  IF NOT EXISTS (
    SELECT 1 FROM potential_customers
    WHERE right(regexp_replace(wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  ) THEN
    INSERT INTO potential_customers (wa, name, shared_by, card_shared, requests)
      VALUES (wa_digits, trim(p_name), 'Scan: ' || ev.title, false,
              'Registered via scan-for-offer QR (' || ev.title || ')');
  END IF;

  RETURN jsonb_build_object(
    'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;
GRANT EXECUTE ON FUNCTION register_event_visitor(uuid, text, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
