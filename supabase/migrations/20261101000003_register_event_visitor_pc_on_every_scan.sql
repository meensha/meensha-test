-- Real bug: register_event_visitor()'s "already registered" branch (an
-- existing coupon for this event+phone) returns immediately with the
-- existing code, before ever reaching the potential_customers dedup/insert
-- further down. So anyone re-scanning a QR they'd already used for this
-- event never gets added to Potential Customers -- confirmed live: a coupon
-- from 2026-10-30 (before either backfill existed) has no matching
-- potential_customers row.
--
-- Fix: do the potential_customers dedup/insert before the already-registered
-- check, so every successful scan (new registration or repeat) is covered.
-- Otherwise identical to 20261101000000's body.

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
  pc_region text;
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

  pc_region := CASE WHEN ev.region IN ('india','australia') THEN ev.region ELSE 'india' END;

  -- Every validated scan -- new or repeat -- gets a Potential Customers row
  -- if this phone number isn't already on the list.
  IF NOT EXISTS (
    SELECT 1 FROM potential_customers
    WHERE right(regexp_replace(wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  ) THEN
    INSERT INTO potential_customers (wa, name, shared_by, card_shared, requests, region)
      VALUES (wa_digits, trim(p_name), 'Scan: ' || ev.title, false,
              'Registered via scan-for-offer QR (' || ev.title || ')', pc_region);
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

  RETURN jsonb_build_object(
    'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;
GRANT EXECUTE ON FUNCTION register_event_visitor(uuid, text, text, text, text) TO anon, authenticated;

-- Backfill the gap this bug already caused: any event_registration coupon
-- with no matching potential_customers row (same check used in
-- 20261101000000, tie-broken on exact event title for the same reason).
INSERT INTO potential_customers (wa, name, shared_by, card_shared, requests, region)
SELECT DISTINCT ON (right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10))
  regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), c.customer_name,
  'Scan: ' || ve.title, false,
  'Registered via scan-for-offer QR (' || ve.title || ')',
  CASE WHEN ve.region IN ('india','australia') THEN ve.region ELSE 'india' END
FROM coupons c
JOIN voucher_events ve ON ve.id = c.event_id
WHERE c.source = 'event_registration'
  AND NOT EXISTS (
    SELECT 1 FROM potential_customers pc
    WHERE right(regexp_replace(pc.wa, '[^0-9]', '', 'g'), 10)
      = right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10)
  )
ORDER BY right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10), c.created_at;

NOTIFY pgrst, 'reload schema';
