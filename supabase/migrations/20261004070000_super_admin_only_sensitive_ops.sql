-- Close the "cosmetic only" gap flagged in this session's admin.html RBAC
-- audit: the UI already hides Users/Razorpay-killswitch/Telegram-allowlist
-- from `owner`, but nothing on the backend enforced it — any logged-in user
-- holding a valid x-admin-session (even `sales` tier) could call the
-- PostgREST API or these RPCs directly and bypass every UI restriction,
-- including setting their OWN `role` column to `super_admin`.
--
-- Three independent fixes, same session-resolution mechanism throughout
-- (require_admin_session() / admin_sessions, from
-- 20260927180000_admin_session_guard.sql — nothing new invented):
--
-- 1. public.users: a BEFORE UPDATE trigger blocks any role change unless the
--    caller's own resolved role is already super_admin. Trusted callers
--    (service_role, pg_cron — require_admin_session() returns NULL for them)
--    are unaffected, same convention as every admin_* RPC.
--
-- 2. Telegram-allowlist and Razorpay/Instagram-secret RPCs (previously the
--    ~20 of ~21 admin_* functions with zero role check) now require
--    super_admin via a new require_super_admin_session() wrapper around the
--    existing require_admin_session(). set_user_password was re-checked and
--    is unaffected — it already requires super_admin/owner/admin to touch
--    someone else's password, which is correct (owners legitimately reset
--    sales-staff passwords) and is left as-is.
--
-- 3. public.overheads (expense add/edit/delete + Shalini/Meenakshi purchase
--    splits) and the split-correction UPDATE path on public.purchases are
--    restricted to super_admin via RESTRICTIVE policies layered on top of
--    the existing admin_session permissive policy — SELECT is untouched
--    (owner keeps read access), and purchases INSERT/DELETE (normal stock
--    recording) are untouched; only the split-editing UPDATE is narrowed.
--
-- Coupons: admin_create_coupon / admin_delete_coupon / admin_set_coupon_active
-- / admin_list_coupons already only require a valid admin session (any
-- role) via require_admin_session(), matching the decision to leave owner's
-- full coupon access as-is. No change here — confirmed, not assumed.

-- ───────────────────────────────────────────────────────────────────────
-- 1. Role-escalation guard on public.users
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_user_role_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    me := require_admin_session();
    IF me.id IS NOT NULL AND me.role <> 'super_admin' THEN
      RAISE EXCEPTION 'not_allowed' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS enforce_user_role_change ON public.users;
CREATE TRIGGER enforce_user_role_change
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_user_role_change();

-- ───────────────────────────────────────────────────────────────────────
-- 2. super_admin-only wrapper, reused by the RPCs below
-- ───────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.require_super_admin_session()
 RETURNS public.users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  IF me.id IS NOT NULL AND me.role <> 'super_admin' THEN
    RAISE EXCEPTION 'not_allowed' USING ERRCODE = '42501';
  END IF;
  RETURN me;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.require_super_admin_session() FROM PUBLIC, anon, authenticated;

-- Telegram allowlist RPCs (India)
CREATE OR REPLACE FUNCTION public.admin_add_telegram_user(p_chat_id text, p_label text)
 RETURNS telegram_allowed_users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r telegram_allowed_users;
BEGIN
  PERFORM require_super_admin_session();
  INSERT INTO telegram_allowed_users (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_telegram_user(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  DELETE FROM telegram_allowed_users WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_telegram_users()
 RETURNS SETOF telegram_allowed_users
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_super_admin_session();
  SELECT * FROM telegram_allowed_users ORDER BY created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_telegram_user_active(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  UPDATE telegram_allowed_users SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

-- Telegram allowlist RPCs (Australia)
CREATE OR REPLACE FUNCTION public.admin_add_telegram_user_au(p_chat_id text, p_label text)
 RETURNS telegram_allowed_users_au
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r telegram_allowed_users_au;
BEGIN
  PERFORM require_super_admin_session();
  INSERT INTO telegram_allowed_users_au (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_telegram_user_au(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  DELETE FROM telegram_allowed_users_au WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_telegram_users_au()
 RETURNS SETOF telegram_allowed_users_au
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT require_super_admin_session();
  SELECT * FROM telegram_allowed_users_au ORDER BY created_at DESC;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_telegram_user_au_active(p_id uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  UPDATE telegram_allowed_users_au SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$function$;

-- Razorpay / Instagram secrets
CREATE OR REPLACE FUNCTION public.admin_set_secret(p_key text, p_value text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  INSERT INTO app_secrets (key, value, updated_at) VALUES (p_key, p_value, now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_secret_is_set(p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM require_super_admin_session();
  RETURN EXISTS (SELECT 1 FROM app_secrets WHERE key = p_key AND value IS NOT NULL AND value <> '');
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────
-- 3. P&L backend restriction: overheads (expenses) + purchases (splits)
-- ───────────────────────────────────────────────────────────────────────
-- admin.html writes these two tables directly over PostgREST (sbIns/sbUpd/
-- sbDel), not through RPCs, so the fix is RLS, not a function check.
-- Resolves the caller's role the same way has_admin_session() resolves
-- whether a session exists at all.
CREATE OR REPLACE FUNCTION public.current_admin_role()
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT u.role FROM admin_sessions s JOIN users u ON u.id = s.user_id
   WHERE s.token_hash = encode(digest(nullif(current_setting('request.headers', true), '')::jsonb->>'x-admin-session', 'sha256'), 'hex')
     AND s.expires_at > now() AND u.active;
$function$;
GRANT EXECUTE ON FUNCTION public.current_admin_role() TO anon;

-- overheads: SELECT stays open to any valid session (owner keeps read
-- access to P&L); INSERT/UPDATE/DELETE (add/edit/delete expense, edit the
-- Shalini/Meenakshi split) now require super_admin. RESTRICTIVE policies
-- AND with the existing admin_session permissive policy rather than
-- replacing it, so a valid session is still required either way.
DROP POLICY IF EXISTS restrict_overheads_insert ON public.overheads;
CREATE POLICY restrict_overheads_insert ON public.overheads AS RESTRICTIVE FOR INSERT TO anon
  WITH CHECK ((SELECT current_admin_role()) = 'super_admin');

DROP POLICY IF EXISTS restrict_overheads_update ON public.overheads;
CREATE POLICY restrict_overheads_update ON public.overheads AS RESTRICTIVE FOR UPDATE TO anon
  USING ((SELECT current_admin_role()) = 'super_admin')
  WITH CHECK ((SELECT current_admin_role()) = 'super_admin');

DROP POLICY IF EXISTS restrict_overheads_delete ON public.overheads;
CREATE POLICY restrict_overheads_delete ON public.overheads AS RESTRICTIVE FOR DELETE TO anon
  USING ((SELECT current_admin_role()) = 'super_admin');

-- purchases: only the split-correction UPDATE (editPurchSplit(), rewriting
-- payment.shalini/payment.meenakshi after the fact) is restricted.
-- INSERT (normal stock-purchase recording, owner+sales as today) and
-- DELETE/SELECT are untouched.
DROP POLICY IF EXISTS restrict_purchase_split_update ON public.purchases;
CREATE POLICY restrict_purchase_split_update ON public.purchases AS RESTRICTIVE FOR UPDATE TO anon
  USING ((SELECT current_admin_role()) = 'super_admin')
  WITH CHECK ((SELECT current_admin_role()) = 'super_admin');
