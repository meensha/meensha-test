-- Prepares for locking the tables to admin sessions (next migration).
-- Additive only: nothing here removes access the live pages rely on.
--
-- Public pages move off the base tables onto:
--   public_skus / public_units      storefront catalog (no cost / vendor data)
--   get_invoice(inv, wa)            invoice.html (WhatsApp match now server-side)
--   staff_forgot_password(u, note)  admin.html login screen
-- and admin.html uses has_admin_session() to notice an expired session.

-- True when the request carries a valid admin session token (see
-- 20260927180000_admin_session_guard.sql). Used by RLS policies and by
-- admin.html's session check.
CREATE FUNCTION public.has_admin_session()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM admin_sessions s JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = encode(digest(nullif(current_setting('request.headers', true), '')::jsonb->>'x-admin-session', 'sha256'), 'hex')
       AND s.expires_at > now() AND u.active
  );
$function$;
GRANT EXECUTE ON FUNCTION public.has_admin_session() TO anon;

-- Storefront catalog. Views run as their owner, so they keep working once the
-- base tables are locked; cost and vendor/purchase links are left out.
CREATE VIEW public.public_skus AS
  SELECT id, sku_code, name, material, tags, mrp, disc, sale_price, sale_price_aud,
         hero_photo, description, created_at, updated_at, display_material,
         display_variant, pattern, variant, photos, india_available, au_available, trending
    FROM public.inventory_skus;
CREATE VIEW public.public_units AS
  SELECT id, sku_id, status FROM public.inventory_units;
-- Read-only: these are auto-updatable views owned by postgres, so a write
-- through them would bypass RLS on the base tables.
REVOKE ALL ON public.public_skus, public.public_units FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.public_skus, public.public_units TO anon;

-- invoice.html: return the sale only when the WhatsApp number matches (last
-- 10 digits, same rule the page used to apply client-side).
CREATE FUNCTION public.get_invoice(p_inv text, p_wa text)
 RETURNS SETOF public.sales
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT * FROM sales
   WHERE inv = p_inv
     AND regexp_replace(coalesce(p_wa, ''), '\D', '', 'g') <> ''
     AND right(regexp_replace(coalesce(customer->>'wa', ''), '\D', '', 'g'), 10)
       = right(regexp_replace(p_wa, '\D', '', 'g'), 10)
   LIMIT 1;
$function$;
GRANT EXECUTE ON FUNCTION public.get_invoice(text, text) TO anon;

-- admin.html "Forgot password" (before login). Returns NULL if the username
-- is unknown, 'super_admin' for the rachnakar flow, otherwise files a reset
-- request and returns 'requested'.
CREATE FUNCTION public.staff_forgot_password(p_username text, p_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_role text;
BEGIN
  SELECT role INTO v_role FROM users WHERE username = p_username;
  IF v_role IS NULL THEN RETURN NULL; END IF;
  IF v_role = 'super_admin' THEN RETURN 'super_admin'; END IF;
  INSERT INTO password_reset_requests (username, note, status) VALUES (p_username, p_note, 'pending');
  RETURN 'requested';
END;
$function$;
GRANT EXECUTE ON FUNCTION public.staff_forgot_password(text, text) TO anon;

-- Storefront cart reservations update inventory_units; run them as owner so
-- they keep working once that table is locked. Bodies unchanged.
ALTER FUNCTION public.reserve_unit(uuid, integer) SECURITY DEFINER SET search_path TO 'public';
ALTER FUNCTION public.unreserve_unit(uuid) SECURITY DEFINER SET search_path TO 'public';
ALTER FUNCTION public.release_expired_reservations() SECURITY DEFINER SET search_path TO 'public';

-- Settings the public pages read (index.html, product.html, about.html).
DROP POLICY "Public read safe settings" ON public.settings;
CREATE POLICY "Public read safe settings" ON public.settings FOR SELECT TO public
  USING (key = ANY (ARRAY['wa_num_in', 'wa_num_au', 'aud_multiplier', 'ticker_messages', 'razorpay_enabled',
                          'shipping_tracking_enabled', 'shipping_tracking_url', 'upi_qr_code_url']));
