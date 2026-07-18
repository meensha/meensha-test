-- Fix: the dedup check in register_visitor() used `existing IS NOT NULL` on
-- a composite (row) type variable. Postgres's composite IS NOT NULL requires
-- ALL fields to be non-null to be true — but an unused coupon always has
-- used_at = NULL, so the check silently failed for every real match,
-- generating a fresh duplicate coupon on every re-registration instead of
-- returning the existing one. Fixed by using PL/pgSQL's built-in FOUND flag,
-- the correct way to test whether a SELECT INTO matched a row.

CREATE OR REPLACE FUNCTION register_visitor(p_name text, p_wa text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
  existing coupons;
  new_code text;
  c coupons;
BEGIN
  IF p_name IS NULL OR trim(p_name) = '' OR length(wa_digits) < 10 THEN
    RETURN jsonb_build_object('error', 'Enter a valid name and WhatsApp number.');
  END IF;

  SELECT * INTO existing FROM coupons
    WHERE source = 'stall_registration'
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'code', existing.code, 'discount_value', existing.discount_value,
      'valid_until', existing.valid_until, 'already_registered', true
    );
  END IF;

  LOOP
    new_code := 'MSH-' || upper(substr(md5(random()::text), 1, 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM coupons WHERE code = new_code);
  END LOOP;

  INSERT INTO coupons (
    code, customer_name, customer_wa, discount_type, discount_value,
    region, valid_from, valid_until, source
  ) VALUES (
    new_code, trim(p_name), wa_digits, 'percent', 5,
    'all', current_date, current_date + 7, 'stall_registration'
  )
  RETURNING * INTO c;

  RETURN jsonb_build_object(
    'code', c.code, 'discount_value', c.discount_value,
    'valid_until', c.valid_until, 'already_registered', false
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
