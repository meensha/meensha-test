-- Two fixes found while testing add_password_security.sql:
--
-- 1. login()/verify_password() failed with "function crypt(text, text) does
--    not exist" — pgcrypto's functions live in the `extensions` schema on
--    Supabase, not `public`. SECURITY DEFINER functions intentionally lock
--    their search_path for safety, which excluded `extensions` here.
--
-- 2. REVOKE SELECT (password_hash) didn't actually stick — re-issuing it
--    against PUBLIC as well as anon/authenticated in case the original grant
--    came from a broader PUBLIC grant that a role-specific REVOKE can't touch.

REVOKE SELECT (password_hash) ON users FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users;
BEGIN
  SELECT * INTO u FROM users
    WHERE username = p_username AND active = true
    AND password_hash = crypt(p_password, password_hash)
  LIMIT 1;

  IF u IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE users SET last_login = now() WHERE id = u.id;

  RETURN jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', u.display_name,
    'role', u.role, 'wa', u.wa, 'active', u.active,
    'must_change_password', u.must_change_password
  );
END;
$$;

CREATE OR REPLACE FUNCTION verify_password(p_user_id uuid, p_password text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE ok boolean;
BEGIN
  SELECT (password_hash = crypt(p_password, password_hash)) INTO ok
    FROM users WHERE id = p_user_id;
  RETURN coalesce(ok, false);
END;
$$;

CREATE OR REPLACE FUNCTION hash_password_trigger()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, extensions AS $$
BEGIN
  IF NEW.password_hash IS NOT NULL AND NEW.password_hash NOT LIKE '$2%' THEN
    NEW.password_hash := crypt(NEW.password_hash, gen_salt('bf'));
  END IF;
  RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION login(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_password(uuid, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
