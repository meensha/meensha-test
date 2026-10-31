-- Fixes a real bug in 20261101000001: require_admin_session() was reused
-- inside the new potential_customers RLS policy, but require_admin_session()
-- was changed on 2026-10-16 (20261016110000_persistent_admin_sessions.sql)
-- to also slide the session's expiry forward on every call (an UPDATE on
-- admin_sessions). That's fine for the RPC calls it was built for -- those
-- run in PostgREST's read-write transaction mode -- but a plain GET (the
-- Potential Customers list) runs in a READ-ONLY transaction, so calling it
-- from an RLS policy on a SELECT fails with "cannot execute UPDATE in a
-- read-only transaction" (SQLSTATE 25006) for every valid session -- found
-- live: Shalini's real session reproduced this exact error, confirmed via
-- a real HTTP GET through the live REST API (not just a SQL simulation,
-- which isn't read-only and had masked this).
--
-- Fix: a read-only sibling that does the identical session lookup, minus
-- the sliding-window UPDATE, used only by the RLS path. require_admin_session()
-- itself is untouched -- every admin_* RPC keeps the sliding-window behavior.

CREATE OR REPLACE FUNCTION public.current_staff_session_readonly()
RETURNS public.users
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
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
$$;
REVOKE EXECUTE ON FUNCTION public.current_staff_session_readonly() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.potential_customers_region_allowed(p_region text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users;
BEGIN
  u := current_staff_session_readonly();
  IF u.id IS NULL THEN RETURN true; END IF;  -- service_role / direct DB callers
  IF u.region IS NULL THEN RETURN true; END IF;  -- shameen: unrestricted
  RETURN u.region = p_region;
END;
$$;
GRANT EXECUTE ON FUNCTION public.potential_customers_region_allowed(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
