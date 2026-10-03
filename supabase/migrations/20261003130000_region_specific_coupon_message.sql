-- validate_coupon's region-mismatch message was a generic "This code isn't
-- valid for this region." — unhelpful when e.g. an Australia-only coupon is
-- tried in India, since it reads the same as every other rejection reason.
-- Makes it name the coupon's actual region so the owner/customer knows why.
-- Both bots (telegram-bot-au/index.ts's kiosk flow) and the website
-- (index.html's ?coupon= deep link) already just display whatever `message`
-- this RPC returns, so this is the only change needed for them. telegram-bot
-- (India)'s own kiosk flow does NOT call this RPC at all (it validates
-- coupons via a separate local check against the coupons table directly),
-- so this message change does not reach it — pre-existing asymmetry, not
-- touched here.
--
-- Does not touch admin_create_coupon (fixed for require_admin_session() in
-- commit b808a84 — left alone per instructions) or anything else in
-- validate_coupon besides this one branch.
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
    RETURN jsonb_build_object('valid', false, 'message',
      CASE c.region
        WHEN 'india' THEN 'This code is India only.'
        WHEN 'australia' THEN 'This code is Australia only.'
        ELSE 'This code isn''t valid for this region.'
      END);
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

NOTIFY pgrst, 'reload schema';
