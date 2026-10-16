-- Persistent admin sessions + real server-side logout.
--
-- Until now, admin.html kept its login session in sessionStorage (so it died
-- on every tab/app close, forcing a re-login) and doLogout() only cleared
-- the client-side copy — the server-side admin_sessions row kept working
-- until its original 24h expiry, so a "logged out" token stayed valid.
--
-- This migration:
--   1. Issues sessions with a 7-day expiry instead of 24h (admin.html now
--      keeps the token in localStorage so it survives restarts).
--   2. Makes require_admin_session() bump a sliding window on every use
--      (expires_at pushed to now()+7d, capped at created_at+30d), so an
--      actively-used session doesn't expire out from under someone, while
--      an abandoned one still dies within 30 days of creation.
--   3. Adds logout_admin_session(token) — a real server-side revoke, called
--      by doLogout() — plus admin_list_my_sessions()/admin_revoke_session()
--      so a user can see and kill their own other sessions. These two never
--      take or return the raw token or its hash: a session is addressed by
--      a surrogate id, since handing a token hash to the browser at all
--      (even just to echo back) defeats the point of only ever storing a
--      hash server-side.

ALTER TABLE admin_sessions ADD COLUMN IF NOT EXISTS last_seen_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE admin_sessions ADD COLUMN IF NOT EXISTS label text;
ALTER TABLE admin_sessions ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();
UPDATE admin_sessions SET id = gen_random_uuid() WHERE id IS NULL;

-- login(): same as before, except the issued session now lasts 7 days
-- instead of 24 hours.
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
    VALUES (encode(digest(v_tok, 'sha256'), 'hex'), u.id, now() + interval '7 days');

  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', u.display_name,
    'role', u.role, 'wa', u.wa, 'active', u.active,
    'must_change_password', u.must_change_password,
    'session_token', v_tok
  );
END;
$function$;

-- require_admin_session(): same lookup as before, but now also slides the
-- session's expiry forward on each use (capped at 30 days from creation)
-- and stamps last_seen_at, so an active session doesn't die mid-use.
CREATE OR REPLACE FUNCTION public.require_admin_session()
 RETURNS public.users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_role text; v_tok text; v_hash text; u users;
BEGIN
  v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role';
  IF v_role IS NULL OR v_role = 'service_role' THEN RETURN NULL; END IF;

  v_tok := nullif(current_setting('request.headers', true), '')::jsonb->>'x-admin-session';
  v_hash := encode(digest(v_tok, 'sha256'), 'hex');
  SELECT us.* INTO u FROM admin_sessions s JOIN users us ON us.id = s.user_id
   WHERE s.token_hash = v_hash
     AND s.expires_at > now() AND us.active;
  IF u.id IS NULL THEN
    RAISE EXCEPTION 'admin_session_invalid' USING ERRCODE = '28000';
  END IF;

  UPDATE admin_sessions
     SET expires_at = LEAST(created_at + interval '30 days', now() + interval '7 days'),
         last_seen_at = now()
   WHERE token_hash = v_hash;

  RETURN u;
END;
$function$;
-- require_admin_session() stays un-grantable to anon/authenticated — same
-- REVOKE as the base migration, just re-asserted since this is a REPLACE.
REVOKE EXECUTE ON FUNCTION public.require_admin_session() FROM PUBLIC, anon, authenticated;

-- Real server-side logout: called by admin.html's doLogout(). Always
-- returns true, even for an already-expired/missing/garbage token, so a
-- logout can never appear to fail to the caller.
CREATE OR REPLACE FUNCTION public.logout_admin_session(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  DELETE FROM admin_sessions WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex');
  RETURN true;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.logout_admin_session(text) TO anon, authenticated;

-- Lists the calling user's own sessions (resolved from their own current
-- session, never from client input) so admin.html can offer an "Active
-- Sessions" list. Never exposes token_hash — only the surrogate id.
CREATE OR REPLACE FUNCTION public.admin_list_my_sessions()
 RETURNS TABLE(id uuid, label text, created_at timestamptz, last_seen_at timestamptz, expires_at timestamptz)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  RETURN QUERY
    SELECT s.id, s.label, s.created_at, s.last_seen_at, s.expires_at
    FROM admin_sessions s
    WHERE s.user_id = me.id
    ORDER BY s.last_seen_at DESC;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_list_my_sessions() TO anon, authenticated;

-- Revokes one of the calling user's own sessions by its surrogate id. The
-- user_id match comes only from the caller's own validated session (via
-- require_admin_session()), never from client input, so this can't be used
-- to guess/revoke another user's session.
CREATE OR REPLACE FUNCTION public.admin_revoke_session(p_session_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE me users;
BEGIN
  me := require_admin_session();
  DELETE FROM admin_sessions WHERE id = p_session_id AND user_id = me.id;
  RETURN FOUND;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.admin_revoke_session(uuid) TO anon, authenticated;
