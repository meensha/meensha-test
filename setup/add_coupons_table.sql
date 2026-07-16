-- M3: Coupon codes — per-customer lock (code + WA number must match at checkout).
-- The table itself is NOT anon-readable (no SELECT policy) so the storefront can't
-- just list/scrape every code + assigned customer's WA number via the REST API.
-- Admin (register view) and the storefront (checkout validation) both go through
-- SECURITY DEFINER RPCs instead, same pattern as reserve_unit/claim_unit.

CREATE TABLE IF NOT EXISTS coupons (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at     timestamptz DEFAULT now(),
  code           text UNIQUE NOT NULL,
  customer_name  text NOT NULL,
  customer_wa    text NOT NULL,
  discount_type  text NOT NULL CHECK (discount_type IN ('percent','flat')),
  discount_value numeric NOT NULL CHECK (discount_value > 0),
  region         text NOT NULL DEFAULT 'all' CHECK (region IN ('india','australia','all')),
  valid_from     date,
  valid_until    date,
  active         boolean NOT NULL DEFAULT true,
  used           boolean NOT NULL DEFAULT false,
  used_at        timestamptz
);

ALTER TABLE coupons ENABLE ROW LEVEL SECURITY;

-- Admin creates/edits/deletes coupons directly with the anon key, same as every
-- other admin.html table in this app. Only SELECT is withheld.
DROP POLICY IF EXISTS "coupons_anon_write" ON coupons;
CREATE POLICY "coupons_anon_write" ON coupons FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "coupons_anon_update" ON coupons;
CREATE POLICY "coupons_anon_update" ON coupons FOR UPDATE TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "coupons_anon_delete" ON coupons;
CREATE POLICY "coupons_anon_delete" ON coupons FOR DELETE TO anon USING (true);

-- Admin register view (returns everything, incl. customer_wa) — used only by admin.html.
CREATE OR REPLACE FUNCTION admin_list_coupons()
RETURNS SETOF coupons
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM coupons ORDER BY created_at DESC;
$$;

-- Storefront checkout check: only returns discount info if code+wa+region+dates+unused
-- all line up. Never exposes the coupon list or other customers' data.
CREATE OR REPLACE FUNCTION validate_coupon(p_code text, p_wa text, p_region text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c coupons;
DECLARE wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
BEGIN
  SELECT * INTO c FROM coupons
    WHERE upper(code) = upper(trim(p_code))
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
  LIMIT 1;

  IF c IS NULL THEN
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

  RETURN jsonb_build_object('valid', true, 'code', c.code, 'discount_type', c.discount_type, 'discount_value', c.discount_value);
END;
$$;

-- Marks a code used. Called after a WhatsApp order is sent, or from the Razorpay
-- webhook once payment is confirmed. Re-validates match so it can't be replayed
-- against a different customer's code.
CREATE OR REPLACE FUNCTION consume_coupon(p_code text, p_wa text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
DECLARE updated_id uuid;
BEGIN
  UPDATE coupons SET used = true, used_at = now()
    WHERE upper(code) = upper(trim(p_code))
    AND right(regexp_replace(customer_wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
    AND used = false AND active = true
    RETURNING id INTO updated_id;
  RETURN updated_id IS NOT NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_coupons() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION validate_coupon(text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION consume_coupon(text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
