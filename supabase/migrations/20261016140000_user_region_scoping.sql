-- Per-user region scoping for the kiosk PWA. 'india'/'australia' locks that
-- staff member to one region (no picker shown); NULL means unrestricted --
-- the kiosk shows a region toggle (India/Australia/All) for that user.
ALTER TABLE users ADD COLUMN IF NOT EXISTS region text CHECK (region IN ('india', 'australia'));

UPDATE users SET region = 'india' WHERE username = 'shalini';
UPDATE users SET region = 'australia' WHERE username = 'meenakshi';
-- shameen intentionally left NULL -- sees the India/Australia/All toggle.

-- login(): same as before, now also returns the caller's region so the
-- client knows whether to lock to one region or show the toggle.
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
    'role', u.role, 'wa', u.wa, 'active', u.active, 'region', u.region,
    'must_change_password', u.must_change_password,
    'session_token', v_tok
  );
END;
$function$;
