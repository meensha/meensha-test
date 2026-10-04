-- Chatbot auth probe.
--
-- The internal "how does this work" chatbot (chatbot/) is a separate small
-- app, outside this repo's Supabase/GitHub Pages stack, that needs to resolve
-- a logged-in staff member's role so it can pick which chatbot/kb/<role>/
-- folder to search. It reuses the existing admin_sessions/users session
-- system (same login() RPC, same x-admin-session token admin.html already
-- uses) rather than inventing its own auth.
--
-- require_admin_session() (20260927180000_admin_session_guard.sql) already
-- does this lookup, but it's deliberately REVOKEd from anon/authenticated —
-- it's meant to be called only from inside another SECURITY DEFINER
-- admin_* function, not invoked directly over PostgREST by a browser/server
-- holding just the anon key. The chatbot server is exactly that kind of
-- caller (it only has the public anon key, same one already embedded in
-- admin.html's own frontend source), so it needs its own narrowly-scoped,
-- read-only probe — not a change to require_admin_session() or its grants.
--
-- Returns {"user_id":..., "role":...} for a valid, unexpired session, or
-- raises admin_session_invalid otherwise (never silently returns a default
-- role). Does not accept trusted/service-role callers the way
-- require_admin_session() does — the chatbot has no service-role caller, so
-- a missing/blank token should always fail, not resolve to NULL.
CREATE OR REPLACE FUNCTION public.verify_admin_session_for_chatbot(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE u users;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RAISE EXCEPTION 'admin_session_invalid' USING ERRCODE = '28000';
  END IF;

  SELECT us.* INTO u FROM admin_sessions s JOIN users us ON us.id = s.user_id
   WHERE s.token_hash = encode(digest(p_token, 'sha256'), 'hex')
     AND s.expires_at > now() AND us.active;

  IF u.id IS NULL THEN
    RAISE EXCEPTION 'admin_session_invalid' USING ERRCODE = '28000';
  END IF;

  RETURN jsonb_build_object('user_id', u.id, 'role', u.role);
END;
$function$;

-- Grantable to anon: this is the one chatbot-auth function meant to be
-- called directly with just the anon key, unlike require_admin_session().
GRANT EXECUTE ON FUNCTION public.verify_admin_session_for_chatbot(text) TO anon;
