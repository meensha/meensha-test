-- Stall registration: public visitors scan a QR code, register with
-- name + WhatsApp, and get a unique one-time coupon immediately.
-- Reuses the existing coupons table/RPCs entirely — no separate tracking
-- table, since admin.html's existing Coupon Register already shows
-- customer name/WA/used-status, which is exactly what's needed here.
--
-- Discount: flat 5% off the whole order, one per WhatsApp number
-- (repeat registrations return their existing code instead of a new one),
-- expires 7 days after registration. Referral program (a second coupon
-- for whoever referred them) is explicitly deferred to a later session —
-- not built here.

ALTER TABLE coupons ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'admin';

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

  -- One coupon per WhatsApp number for stall registrations specifically —
  -- if they've already registered, hand back their existing code rather
  -- than minting a new one.
  SELECT * INTO existing FROM coupons
    WHERE source = 'stall_registration'
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  LIMIT 1;

  IF existing IS NOT NULL THEN
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

GRANT EXECUTE ON FUNCTION register_visitor(text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
