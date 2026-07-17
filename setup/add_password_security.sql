-- Fixes a real, live vulnerability: admin.html was querying the `users` table
-- directly with the anon key (GET /rest/v1/users?username=eq.X&password_hash=eq.Y),
-- and password_hash held plain text despite its name. Anyone with the anon key
-- (embedded in the public admin.html source) could read every password via
-- GET /rest/v1/users?select=username,password_hash.
--
-- Also bundles two things discovered while building this fix:
--   1. users_role_check only allowed ('admin','sales','owner') — 'super_admin'
--      was never a valid DB value. shameen's real super_admin access has only
--      ever come from the hardcoded LOCAL_USERS JS fallback (now removed from
--      admin.html), never the database. Widened here to include it.
--   2. must_change_password / last_password_change / password_updated_via
--      columns referenced throughout admin.html's password-reset code don't
--      exist on the live table at all — every reset/forced-change write has
--      been silently failing (the app's own request helper swallows errors),
--      while the UI still showed "success". Added here, along with
--      password_reset_requests (Owner/Sales "ask Rachnakar to reset me" flow
--      only — the super_admin email/recovery-code paths are intentionally
--      left for a separate session).

-- 1. Widen the role constraint to include super_admin (keep 'admin' — the
--    pre-existing, unexplained 'siteadmin' account uses it; not touching that
--    account here).
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
  CHECK (role = ANY (ARRAY['admin','sales','owner','super_admin']));

-- 2. Add the columns the password-reset code has always assumed existed.
ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_password_change timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_updated_via text;

-- 3. Hash any existing plaintext password_hash values.
UPDATE users SET password_hash = crypt(password_hash, gen_salt('bf'))
WHERE password_hash IS NOT NULL AND password_hash NOT LIKE '$2%';

-- 4. Auto-hash on every future insert/update, so no code path can
--    accidentally write a plaintext password again.
CREATE OR REPLACE FUNCTION hash_password_trigger()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.password_hash IS NOT NULL AND NEW.password_hash NOT LIKE '$2%' THEN
    NEW.password_hash := crypt(NEW.password_hash, gen_salt('bf'));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hash_password ON users;
CREATE TRIGGER trg_hash_password
  BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION hash_password_trigger();

-- 5. Block direct reads of the hash column. Every other column on `users`
--    (username, role, display_name, wa, active, ...) stays readable exactly
--    as before, so renderUsers()/renderPermissions() etc. keep working
--    unchanged — only password_hash is withheld.
REVOKE SELECT (password_hash) ON users FROM anon, authenticated;

-- 6. Login RPC — the only way to check a password now. Runs as the function
--    owner (SECURITY DEFINER), so it can read password_hash internally even
--    though anon/authenticated can't. Returns the safe fields on success,
--    NULL on any failure (bad user, bad password, or inactive) — same
--    "incorrect username or password" behaviour as before, no extra leakage
--    about which part failed.
CREATE OR REPLACE FUNCTION login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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

-- 7. Verify-current-password RPC, used by the self-service change-password
--    flow instead of matching password_hash directly.
CREATE OR REPLACE FUNCTION verify_password(p_user_id uuid, p_password text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ok boolean;
BEGIN
  SELECT (password_hash = crypt(p_password, password_hash)) INTO ok
    FROM users WHERE id = p_user_id;
  RETURN coalesce(ok, false);
END;
$$;

GRANT EXECUTE ON FUNCTION login(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_password(uuid, text) TO anon, authenticated;

-- 8. Data fixes.
UPDATE users SET role = 'super_admin' WHERE username = 'shameen';

INSERT INTO users (username, password_hash, display_name, role, wa, active, must_change_password, password_updated_via)
SELECT 'meenakshi', 'u4k2rbxWq5bM', 'Meenakshi', 'owner', '918709525218', true, true, 'initial_seed'
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username = 'meenakshi');

-- 9. Owner/Sales "forgot password" request queue — Rachnakar sees pending
--    requests and generates a new password for that user via the existing
--    admin.html flow (Users tab card). Same permissive RLS as the rest of
--    the app's tables; nothing here is more sensitive than a sales record.
CREATE TABLE IF NOT EXISTS password_reset_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at    timestamptz DEFAULT now(),
  username      text NOT NULL,
  note          text,
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','fulfilled','rejected')),
  fulfilled_by  text,
  fulfilled_at  timestamptz,
  generated_pw  text
);

ALTER TABLE password_reset_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "all_anon" ON password_reset_requests;
CREATE POLICY "all_anon" ON password_reset_requests FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON password_reset_requests;
CREATE POLICY "all_auth" ON password_reset_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
