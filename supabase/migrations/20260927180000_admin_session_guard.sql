-- Admin session guard.
--
-- admin.html talks to PostgREST with the public anon key, so before this
-- migration every SECURITY DEFINER admin_* function (and set_user_password)
-- could be called by anyone holding that key — i.e. anyone who opened the
-- storefront. login() now issues a random session token (only its sha256 is
-- stored); admin.html sends it as the x-admin-session header, and each admin
-- function checks it via require_admin_session(). Service-role callers (edge
-- functions, Telegram bots) and direct DB callers (pg_cron) are trusted and
-- pass without a token.
--
-- Also revokes anon/authenticated EXECUTE on functions that only edge
-- functions call — notably create_customer_otp, which let anyone mint a known
-- OTP for any customer email and then reset that customer's password.

CREATE TABLE public.admin_sessions (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);
ALTER TABLE public.admin_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_sessions FROM anon, authenticated;

-- Returns the logged-in staff user, or NULL for trusted (service-role / direct
-- DB) callers. Raises admin_session_invalid otherwise.
CREATE FUNCTION public.require_admin_session()
 RETURNS public.users
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_role text; v_tok text; u users;
BEGIN
  v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role';
  IF v_role IS NULL OR v_role = 'service_role' THEN RETURN NULL; END IF;

  v_tok := nullif(current_setting('request.headers', true), '')::jsonb->>'x-admin-session';
  SELECT us.* INTO u FROM admin_sessions s JOIN users us ON us.id = s.user_id
   WHERE s.token_hash = encode(digest(v_tok, 'sha256'), 'hex')
     AND s.expires_at > now() AND us.active;
  IF u.id IS NULL THEN
    RAISE EXCEPTION 'admin_session_invalid' USING ERRCODE = '28000';
  END IF;
  RETURN u;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.require_admin_session() FROM PUBLIC, anon, authenticated;

-- login(): now also returns session_token.
CREATE OR REPLACE FUNCTION public.login(p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE u users; ph text; v_tok text;
BEGIN
  SELECT * INTO u FROM users WHERE username = p_username AND active = true;
  IF u IS NULL THEN RETURN NULL; END IF;

  SELECT password_hash INTO ph FROM user_credentials WHERE user_id = u.id;
  IF ph IS NULL OR ph != crypt(p_password, ph) THEN RETURN NULL; END IF;

  UPDATE users SET last_login = now() WHERE id = u.id;

  DELETE FROM admin_sessions WHERE expires_at < now();
  v_tok := encode(gen_random_bytes(32), 'hex');
  INSERT INTO admin_sessions (token_hash, user_id, expires_at)
    VALUES (encode(digest(v_tok, 'sha256'), 'hex'), u.id, now() + interval '24 hours');

  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', u.display_name,
    'role', u.role, 'wa', u.wa, 'active', u.active,
    'must_change_password', u.must_change_password,
    'session_token', v_tok
  );
END;
$function$;

-- set_user_password(): requires a session; only managers may set someone else's.
CREATE OR REPLACE FUNCTION public.set_user_password(p_user_id uuid, p_new_password text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  IF me.id IS NOT NULL AND me.id <> p_user_id
     AND me.role NOT IN ('super_admin', 'owner', 'admin') THEN
    RAISE EXCEPTION 'not_allowed' USING ERRCODE = '42501';
  END IF;

  INSERT INTO user_credentials (user_id, password_hash)
  VALUES (p_user_id, p_new_password)
  ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash;
  RETURN true;
END;
$function$;

-- admin_* functions: require a session. Bodies otherwise unchanged.
CREATE OR REPLACE FUNCTION public.admin_add_telegram_user(p_chat_id text, p_label text)
 RETURNS telegram_allowed_users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r telegram_allowed_users;
BEGIN
  PERFORM require_admin_session();
  INSERT INTO telegram_allowed_users (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_telegram_user_au(p_chat_id text, p_label text)
 RETURNS telegram_allowed_users_au
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r telegram_allowed_users_au;
BEGIN
  PERFORM require_admin_session();
  INSERT INTO telegram_allowed_users_au (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_approve_purchase_batch(p_batch_id uuid, p_reviewed_by text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase_id  uuid;
  v_vendor_uuid  uuid;
  v_vendor_code  text;
  v_payment      jsonb;
  v_region       text;
  v_items        jsonb := '[]'::jsonb;
  v_total        numeric := 0;
  v_row          record;
  v_sku_id       uuid;
  v_sku_code     text;
  v_units_affected integer := 0;
  v_pending_count  integer;
BEGIN
  PERFORM require_admin_session();
  SELECT vendor_uuid, payment, region INTO v_vendor_uuid, v_payment, v_region
  FROM stock_intake_drafts WHERE batch_id = p_batch_id LIMIT 1;

  IF v_vendor_uuid IS NULL THEN
    RAISE EXCEPTION 'Batch % has no vendor or does not exist', p_batch_id;
  END IF;

  SELECT count(*) INTO v_pending_count
  FROM stock_intake_drafts WHERE batch_id = p_batch_id AND status = 'pending';
  IF v_pending_count = 0 THEN
    RAISE EXCEPTION 'Batch % has no pending items left to approve', p_batch_id;
  END IF;

  SELECT vendor_id INTO v_vendor_code FROM vendors WHERE id = v_vendor_uuid;

  INSERT INTO purchases (vendor_uuid, vendor_code, date, payment, items, total, sub)
  VALUES (v_vendor_uuid, v_vendor_code, CURRENT_DATE, v_payment, '[]'::jsonb, 0, 0)
  RETURNING id INTO v_purchase_id;

  FOR v_row IN
    SELECT * FROM stock_intake_drafts
    WHERE batch_id = p_batch_id AND status = 'pending'
    ORDER BY created_at
  LOOP
    IF v_row.is_defective THEN
      INSERT INTO inventory_returns_pending (sku_id, purchase_id, vendor_uuid, qty, reason, photo_url, flagged_by)
      VALUES (
        v_row.sku_id, v_purchase_id, v_vendor_uuid,
        COALESCE(v_row.defect_qty, v_row.qty), v_row.defect_reason,
        v_row.photo_urls->>0, p_reviewed_by
      );
    ELSE
      v_sku_id := v_row.sku_id;
      IF v_sku_id IS NULL THEN
        v_sku_code := upper(left(regexp_replace(coalesce(v_row.proposed_name, 'ITEM'), '[^a-zA-Z0-9]+', '', 'g'), 10))
          || '-' || to_char(now(), 'MMDD') || '-' || substr(md5(random()::text), 1, 4);
        WHILE EXISTS (SELECT 1 FROM inventory_skus WHERE sku_code = v_sku_code) LOOP
          v_sku_code := v_sku_code || substr(md5(random()::text), 1, 2);
        END LOOP;

        IF v_row.region = 'australia' THEN
          INSERT INTO inventory_skus (
            sku_code, name, material, variant, display_material, display_variant,
            sale_price_aud, au_available, india_available, cost, photos
          ) VALUES (
            v_sku_code, v_row.proposed_name, v_row.proposed_material, v_row.proposed_variant,
            v_row.proposed_material, v_row.proposed_variant,
            v_row.proposed_sale_price, true, false, v_row.purchase_price, v_row.photo_urls
          )
          RETURNING id INTO v_sku_id;
        ELSE
          INSERT INTO inventory_skus (
            sku_code, name, material, variant, display_material, display_variant,
            sale_price, india_available, au_available, cost, photos
          ) VALUES (
            v_sku_code, v_row.proposed_name, v_row.proposed_material, v_row.proposed_variant,
            v_row.proposed_material, v_row.proposed_variant,
            v_row.proposed_sale_price, true, false, v_row.purchase_price, v_row.photo_urls
          )
          RETURNING id INTO v_sku_id;
        END IF;
      END IF;

      PERFORM create_batch_units(
        p_sku_id := v_sku_id,
        p_vendor_code := v_vendor_code,
        p_purchase_id := v_purchase_id,
        p_qty := v_row.qty,
        p_photo_urls := ARRAY(SELECT jsonb_array_elements_text(v_row.photo_urls))
      );
      v_units_affected := v_units_affected + v_row.qty;
    END IF;

    v_items := v_items || jsonb_build_object(
      'name', v_row.proposed_name,
      'material', v_row.proposed_material,
      'variant', v_row.proposed_variant,
      'qty', v_row.qty,
      'cost', v_row.purchase_price,
      'defective', v_row.is_defective
    );
    v_total := v_total + COALESCE(v_row.purchase_price, 0) * v_row.qty;

    UPDATE stock_intake_drafts
    SET status = 'approved', reviewed_by = p_reviewed_by, reviewed_at = now()
    WHERE id = v_row.id;
  END LOOP;

  UPDATE purchases SET items = v_items, total = v_total, sub = v_total WHERE id = v_purchase_id;

  INSERT INTO vendor_audit_log (vendor_uuid, action, new_value, performed_by, units_affected)
  VALUES (v_vendor_uuid, 'purchase_approved', v_purchase_id::text, p_reviewed_by, v_units_affected);

  RETURN v_purchase_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_approve_stock_intake_draft(p_draft_id uuid, p_reviewed_by text, p_vendor_code text, p_purchase_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE d stock_intake_drafts; v_sku_id uuid; v_result jsonb;
BEGIN
  PERFORM require_admin_session();
  SELECT * INTO d FROM stock_intake_drafts WHERE id = p_draft_id AND status = 'pending';
  IF d IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Draft not found or already reviewed.');
  END IF;

  v_sku_id := d.sku_id;
  IF v_sku_id IS NULL THEN
    INSERT INTO inventory_skus (
      sku_code, name, material, variant, cost, sale_price, sale_price_aud,
      photos, india_available, au_available
    ) VALUES (
      'AU-' || to_char(now(), 'YYMMDDHH24MISS'),
      d.proposed_name, d.proposed_material, d.proposed_variant,
      COALESCE(d.purchase_price, 0),
      CASE WHEN d.region = 'india' THEN COALESCE(d.proposed_sale_price, 0) ELSE 0 END,
      CASE WHEN d.region = 'australia' THEN COALESCE(d.proposed_sale_price, 0) ELSE 0 END,
      d.photo_urls,
      d.region = 'india', d.region = 'australia'
    ) RETURNING id INTO v_sku_id;
  END IF;

  SELECT jsonb_agg(row_to_json(u)) INTO v_result
  FROM create_batch_units(v_sku_id, p_vendor_code, p_purchase_id, d.qty,
    ARRAY(SELECT jsonb_array_elements_text(d.photo_urls))) u;

  UPDATE stock_intake_drafts
     SET status = 'approved', reviewed_by = p_reviewed_by, reviewed_at = now()
   WHERE id = p_draft_id;

  RETURN jsonb_build_object('ok', true, 'sku_id', v_sku_id, 'units', v_result);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_coupon(p_code text, p_customer_name text, p_customer_wa text, p_discount_type text, p_discount_value numeric, p_region text, p_valid_from date, p_valid_until date, p_category_filter text DEFAULT NULL::text)
 RETURNS coupons
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE c coupons;
BEGIN
  PERFORM require_admin_session();
  INSERT INTO coupons(code, customer_name, customer_wa, discount_type, discount_value, region, valid_from, valid_until, category_filter)
  VALUES (upper(trim(p_code)), nullif(p_customer_name, ''), nullif(p_customer_wa, ''), p_discount_type, p_discount_value, p_region, p_valid_from, p_valid_until, nullif(p_category_filter, ''))
  RETURNING * INTO c;
  RETURN c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_voucher_event(p_title text, p_region text, p_discount_type text, p_discount_value numeric, p_valid_days integer, p_created_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE ev voucher_events;
BEGIN
  PERFORM require_admin_session();
  INSERT INTO voucher_events (title, region, discount_type, discount_value, valid_days, created_by)
  VALUES (p_title, p_region, p_discount_type, p_discount_value, COALESCE(p_valid_days, 7), p_created_by)
  RETURNING * INTO ev;
  RETURN jsonb_build_object('id', ev.id, 'title', ev.title);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_coupon(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  DELETE FROM coupons WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_telegram_user(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  DELETE FROM telegram_allowed_users WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_telegram_user_au(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  DELETE FROM telegram_allowed_users_au WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_coupons()
 RETURNS SETOF coupons
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_admin_session();
  SELECT * FROM coupons ORDER BY created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_stock_intake_drafts(p_status text DEFAULT 'pending'::text)
 RETURNS SETOF stock_intake_drafts
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_admin_session();
  SELECT * FROM stock_intake_drafts WHERE status = p_status ORDER BY created_at ASC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_telegram_users()
 RETURNS SETOF telegram_allowed_users
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_admin_session();
  SELECT * FROM telegram_allowed_users ORDER BY created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_telegram_users_au()
 RETURNS SETOF telegram_allowed_users_au
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_admin_session();
  SELECT * FROM telegram_allowed_users_au ORDER BY created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reject_purchase_batch(p_batch_id uuid, p_reason text, p_reviewed_by text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE stock_intake_drafts
  SET status = 'rejected', rejection_reason = p_reason, reviewed_by = p_reviewed_by, reviewed_at = now()
  WHERE batch_id = p_batch_id AND status = 'pending';
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reject_stock_intake_draft(p_draft_id uuid, p_reviewed_by text, p_reason text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE stock_intake_drafts
     SET status = 'rejected', reviewed_by = p_reviewed_by, reviewed_at = now(), rejection_reason = p_reason
   WHERE id = p_draft_id AND status = 'pending';
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_secret_is_set(p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  RETURN EXISTS (SELECT 1 FROM app_secrets WHERE key = p_key AND value IS NOT NULL AND value <> '');
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_coupon_active(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE coupons SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_secret(p_key text, p_value text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  INSERT INTO app_secrets (key, value, updated_at) VALUES (p_key, p_value, now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_telegram_user_active(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE telegram_allowed_users SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_telegram_user_au_active(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_admin_session();
  UPDATE telegram_allowed_users_au SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

-- Functions only edge functions call (service role). Revoke from browser roles.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = ANY (ARRAY['create_customer_otp', 'request_password_reset', 'start_customer_signup', 'verify_customer_signup_otp', 'verify_password_reset', 'add_event_photo', 'get_unposted_event_photos', 'mark_event_photos_posted', 'append_sku_photo', 'submit_purchase_intake_batch', 'submit_stock_intake_draft'])
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.fn);
  END LOOP;
END $$;
