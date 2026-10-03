-- Adds an opt-in single_use flag for public coupons (setup/add_public_coupons.sql
-- made public codes — customer_wa IS NULL — permanently reusable, by design, for
-- promos like FREEDOM200). Some codes need to be public (not locked to one
-- customer's WA number) but still only redeemable once total — e.g. a one-time
-- code handed to a partner org rather than an individual. single_use covers that
-- without touching the FREEDOM200-style reusable behavior.
--
-- Defaults to false and is NOT NULL, so every existing coupon row (public or
-- locked) keeps its exact current behavior after this migration — nothing here
-- changes behavior for rows that already exist.

ALTER TABLE coupons ADD COLUMN IF NOT EXISTS single_use boolean NOT NULL DEFAULT false;

-- consume_coupon: locked codes (customer_wa IS NOT NULL) already get marked
-- used on first successful redemption regardless of single_use — unchanged.
-- Public codes (customer_wa IS NULL) stay reusable forever when single_use is
-- false (unchanged, the FREEDOM200 case) but now get flipped to used=true on
-- their first successful redemption when single_use is true, and a second
-- redemption attempt then correctly fails (used = true).
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
    IF NOT c.single_use THEN
      RETURN true; -- reusable public code: nothing to flip, just confirm it's still valid/active
    END IF;
    UPDATE coupons SET used = true, used_at = now()
      WHERE id = c.id AND used = false
    RETURNING id INTO updated_id;
    RETURN updated_id IS NOT NULL;
  END IF;

  UPDATE coupons SET used = true, used_at = now()
    WHERE id = c.id
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
    AND used = false
  RETURNING id INTO updated_id;
  RETURN updated_id IS NOT NULL;
END;
$$;

-- admin_create_coupon needs the new p_single_use param. Drop the old 9-arg
-- signature first so PostgREST doesn't end up with two ambiguous overloads
-- of the same function name (same precaution add_public_coupons.sql took).
DROP FUNCTION IF EXISTS admin_create_coupon(text,text,text,text,numeric,text,date,date,text);
CREATE OR REPLACE FUNCTION admin_create_coupon(
  p_code text, p_customer_name text, p_customer_wa text,
  p_discount_type text, p_discount_value numeric, p_region text,
  p_valid_from date, p_valid_until date, p_category_filter text DEFAULT NULL,
  p_single_use boolean DEFAULT false
)
RETURNS coupons
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c coupons;
BEGIN
  INSERT INTO coupons(code, customer_name, customer_wa, discount_type, discount_value, region, valid_from, valid_until, category_filter, single_use)
  VALUES (upper(trim(p_code)), nullif(p_customer_name, ''), nullif(p_customer_wa, ''), p_discount_type, p_discount_value, p_region, p_valid_from, p_valid_until, nullif(p_category_filter, ''), p_single_use)
  RETURNING * INTO c;
  RETURN c;
END;
$$;
GRANT EXECUTE ON FUNCTION admin_create_coupon(text,text,text,text,numeric,text,date,date,text,boolean) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
