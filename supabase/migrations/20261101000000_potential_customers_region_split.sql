-- Split potential_customers by market (india/australia), same convention
-- users.region / voucher_events.region already use. Previously every row
-- was visible to every owner regardless of market -- Meenakshi saw
-- Shalini's India leads and vice versa. Locked logins (shalini/meenakshi)
-- will only see their own region; shameen (region NULL) keeps the existing
-- India/Australia/All toggle, now applied to this screen too.

ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS region text;

-- Backfill: the only two paths that ever wrote a row before today were
-- submitShareCard()/sendPcnSelected() in kiosk.html (shared_by = the
-- logged-in staff username -- only shalini/meenakshi have the share-card
-- icon, and the PCN "+New" entry screen is india-only) and, as of
-- yesterday, register_event_visitor() (shared_by = 'Scan: <event title>').
UPDATE potential_customers SET region = 'india' WHERE lower(shared_by) = 'shalini';
UPDATE potential_customers SET region = 'australia' WHERE lower(shared_by) = 'meenakshi';

-- Tie-broken on pc.shared_by = 'Scan: <title>' matching that exact event's
-- title, not just the phone number: someone who scanned two differently-
-- regioned events only gets one potential_customers row (register_event_
-- visitor dedups by phone), so a title-blind join could pair it with the
-- wrong event's coupon row and mis-tag its region.
UPDATE potential_customers pc
  SET region = ve.region
  FROM coupons c
  JOIN voucher_events ve ON ve.id = c.event_id
  WHERE pc.region IS NULL
    AND pc.shared_by = 'Scan: ' || ve.title
    AND right(regexp_replace(pc.wa, '[^0-9]', '', 'g'), 10)
      = right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10);

-- Anything still unmatched (shouldn't be any given the above, but a stray
-- event with region='all' would fall through the backfill) defaults to
-- india -- every historical direct-entry path besides meenakshi's own
-- login was india-only.
UPDATE potential_customers SET region = 'india' WHERE region IS NULL;

ALTER TABLE potential_customers ALTER COLUMN region SET NOT NULL;
ALTER TABLE potential_customers ALTER COLUMN region SET DEFAULT 'india';
ALTER TABLE potential_customers ADD CONSTRAINT potential_customers_region_check
  CHECK (region IN ('india', 'australia'));

-- save_potential_customer() (kiosk "share visiting card" + PCN "+New" flow)
-- now takes the caller's region explicitly, same pattern p_shared_by already
-- uses -- the RPC is anon-callable so it can't infer it from a session.
DROP FUNCTION IF EXISTS public.save_potential_customer(text, text, text);
CREATE OR REPLACE FUNCTION public.save_potential_customer(p_wa text, p_name text, p_shared_by text, p_region text DEFAULT 'india')
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
  region_clean text := CASE WHEN p_region IN ('india','australia') THEN p_region ELSE 'india' END;
BEGIN
  IF length(wa_digits) <> 10 THEN
    RAISE EXCEPTION 'A 10-digit WhatsApp number is required';
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'A name is required';
  END IF;
  INSERT INTO potential_customers (wa, name, shared_by, card_shared, region)
    VALUES (wa_digits, trim(p_name), COALESCE(p_shared_by, 'unknown'), true, region_clean);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_potential_customer(text, text, text, text) TO anon, authenticated;

-- register_event_visitor() now tags the potential_customers row with the
-- event's own region instead of implicitly defaulting to india. Otherwise
-- identical to 20261031000000's body.
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

  pc_region := CASE WHEN ev.region IN ('india','australia') THEN ev.region ELSE 'india' END;

  IF NOT EXISTS (
    SELECT 1 FROM potential_customers
    WHERE right(regexp_replace(wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  ) THEN
    INSERT INTO potential_customers (wa, name, shared_by, card_shared, requests, region)
      VALUES (wa_digits, trim(p_name), 'Scan: ' || ev.title, false,
              'Registered via scan-for-offer QR (' || ev.title || ')', pc_region);
  END IF;

  RETURN jsonb_build_object(
    'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;
GRANT EXECUTE ON FUNCTION register_event_visitor(uuid, text, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
