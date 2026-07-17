-- The column-level REVOKE SELECT (password_hash) approach didn't stick —
-- explicit column grants for anon/authenticated kept reappearing (confirmed
-- via information_schema.column_privileges). Rather than keep fighting an
-- unclear re-grant source, use the same pattern already proven elsewhere in
-- this app for the `orders` table: put the sensitive data in its own table
-- with RLS enabled and *no* policies for anon/authenticated at all. There's
-- nothing column-level to bypass — the anon key simply has zero access to
-- this table, full stop. Only our SECURITY DEFINER RPCs (which bypass RLS by
-- running as the function owner) can read or write it.

CREATE TABLE IF NOT EXISTS user_credentials (
  user_id       uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  password_hash text NOT NULL
);
ALTER TABLE user_credentials ENABLE ROW LEVEL SECURITY;
-- Intentionally no policies: anon/authenticated get zero access by default,
-- same as `orders`.

-- Migrate existing hashes across, then drop the leaky column entirely so
-- there's nothing left on `users` for any future grant confusion to expose.
INSERT INTO user_credentials (user_id, password_hash)
SELECT id, password_hash FROM users WHERE password_hash IS NOT NULL
ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash;

DROP TRIGGER IF EXISTS trg_hash_password ON users;
DROP FUNCTION IF EXISTS hash_password_trigger();
ALTER TABLE users DROP COLUMN IF EXISTS password_hash;

-- Auto-hash on every future write to user_credentials.
CREATE OR REPLACE FUNCTION hash_password_trigger()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, extensions AS $$
BEGIN
  IF NEW.password_hash IS NOT NULL AND NEW.password_hash NOT LIKE '$2%' THEN
    NEW.password_hash := crypt(NEW.password_hash, gen_salt('bf'));
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hash_password
  BEFORE INSERT OR UPDATE ON user_credentials
  FOR EACH ROW EXECUTE FUNCTION hash_password_trigger();

-- Rewire login()/verify_password() to the new table.
CREATE OR REPLACE FUNCTION login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users; ph text;
BEGIN
  SELECT * INTO u FROM users WHERE username = p_username AND active = true;
  IF u IS NULL THEN RETURN NULL; END IF;

  SELECT password_hash INTO ph FROM user_credentials WHERE user_id = u.id;
  IF ph IS NULL OR ph != crypt(p_password, ph) THEN RETURN NULL; END IF;

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
DECLARE ph text;
BEGIN
  SELECT password_hash INTO ph FROM user_credentials WHERE user_id = p_user_id;
  RETURN ph IS NOT NULL AND ph = crypt(p_password, ph);
END;
$$;

-- Every password write (self-change, admin create/edit, Rachnakar-generated
-- reset) now goes through this instead of touching users.password_hash
-- directly, since that column no longer exists.
CREATE OR REPLACE FUNCTION set_user_password(p_user_id uuid, p_new_password text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  INSERT INTO user_credentials (user_id, password_hash)
  VALUES (p_user_id, p_new_password)
  ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION login(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_password(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION set_user_password(uuid, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
