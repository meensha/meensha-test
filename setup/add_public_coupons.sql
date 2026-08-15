-- Extends the coupon engine (setup/add_coupons_table.sql) with two things
-- it didn't originally support: public codes (not locked to one customer's
-- WA number) and category-scoped discounts (only applies to matching line
-- items, not the whole cart). Built for the FREEDOM200 Independence Day
-- promo — a reusable public code, ₹200 off, matching any product with
-- "dupatta" in its name.
--
-- customer_wa/customer_name become nullable: NULL means "public code, any
-- customer." category_filter is a plain case-insensitive substring matched
-- against each cart item's name (same convention the storefront's own
-- category filter — matchF() in index.html — already uses), NULL means
-- "applies to the whole cart" (unchanged behavior for existing coupons).

ALTER TABLE coupons ALTER COLUMN customer_wa DROP NOT NULL;
ALTER TABLE coupons ALTER COLUMN customer_name DROP NOT NULL;
ALTER TABLE coupons ADD COLUMN IF NOT EXISTS category_filter text;

-- Public codes (customer_wa IS NULL) skip the WA match entirely. Also now
-- returns category_filter so the storefront knows what subset of the cart
-- to discount.
CREATE OR REPLACE FUNCTION validate_coupon(p_code text, p_wa text, p_region text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c coupons;
DECLARE wa_digits text := regexp_replace(coalesce(p_wa, ''), '[^0-9]', '', 'g');
BEGIN
  SELECT * INTO c FROM coupons WHERE upper(code) = upper(trim(p_code)) LIMIT 1;

  IF c IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'message', 'Code not found.');
  END IF;
  IF c.customer_wa IS NOT NULL
     AND right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10) <> right(wa_digits, 10) THEN
    RETURN jsonb_build_object('valid', false, 'message', 'Code not found, or the WhatsApp number doesn''t match.');
  END IF;
  IF NOT c.active THEN
    RETURN jsonb_build_object('valid', false, 'message', 'This code is no longer active.');
  END IF;
  IF c.used THEN
    RETURN jsonb_build_object('valid', false, 'message', 'This code has already been used.');
  END IF;
  IF c.region NOT IN ('all', p_region) THEN
    RETURN jsonb_build_object('valid', false, 'message', 'This code isn''t valid for this region.');
  END IF;
  IF c.valid_from IS NOT NULL AND current_date < c.valid_from THEN
    RETURN jsonb_build_object('valid', false, 'message', 'This code isn''t active yet.');
  END IF;
  IF c.valid_until IS NOT NULL AND current_date > c.valid_until THEN
    RETURN jsonb_build_object('valid', false, 'message', 'This code has expired.');
  END IF;

  RETURN jsonb_build_object('valid', true, 'code', c.code, 'discount_type', c.discount_type,
    'discount_value', c.discount_value, 'category_filter', c.category_filter, 'public', c.customer_wa IS NULL);
END;
$$;

-- Public codes (customer_wa IS NULL) are reusable — never flip `used`, so
-- the same code keeps working for every customer through its valid_until
-- date. Note: no per-customer redemption cap in this pass, so in principle
-- the same person could reuse a public code more than once (acceptable for
-- a time-boxed launch promo; flag if per-customer capping is wanted later).
CREATE OR REPLACE FUNCTION consume_coupon(p_code text, p_wa text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE wa_digits text := regexp_replace(coalesce(p_wa, ''), '[^0-9]', '', 'g');
DECLARE c coupons;
DECLARE updated_id uuid;
BEGIN
  SELECT * INTO c FROM coupons WHERE upper(code) = upper(trim(p_code)) AND active = true;
  IF c IS NULL THEN RETURN false; END IF;

  IF c.customer_wa IS NULL THEN
    RETURN true; -- public code: nothing to flip, just confirm it's still valid/active
  END IF;

  UPDATE coupons SET used = true, used_at = now()
    WHERE id = c.id
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
    AND used = false
  RETURNING id INTO updated_id;
  RETURN updated_id IS NOT NULL;
END;
$$;

-- admin_create_coupon (setup/fix_coupons_admin_rpcs.sql) needs the new
-- category_filter param, and customer_name/customer_wa now genuinely
-- optional (NULL/blank = public code) instead of always-required. Drop the
-- old 8-arg signature first so PostgREST doesn't end up with two ambiguous
-- overloads of the same function name.
DROP FUNCTION IF EXISTS admin_create_coupon(text,text,text,text,numeric,text,date,date);
CREATE OR REPLACE FUNCTION admin_create_coupon(
  p_code text, p_customer_name text, p_customer_wa text,
  p_discount_type text, p_discount_value numeric, p_region text,
  p_valid_from date, p_valid_until date, p_category_filter text DEFAULT NULL
)
RETURNS coupons
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c coupons;
BEGIN
  INSERT INTO coupons(code, customer_name, customer_wa, discount_type, discount_value, region, valid_from, valid_until, category_filter)
  VALUES (upper(trim(p_code)), nullif(p_customer_name, ''), nullif(p_customer_wa, ''), p_discount_type, p_discount_value, p_region, p_valid_from, p_valid_until, nullif(p_category_filter, ''))
  RETURNING * INTO c;
  RETURN c;
END;
$$;
GRANT EXECUTE ON FUNCTION admin_create_coupon(text,text,text,text,numeric,text,date,date,text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
