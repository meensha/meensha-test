-- Replaces the single comma-separated telegram_authorized_chat_id setting
-- with a real, manageable table + admin.html UI (list, add, revoke).
--
-- Writes are RPC-only, not open anon INSERT/UPDATE/DELETE — a row in this
-- table grants real bot access (ability to execute sales/inventory actions
-- as if logged into admin.html), so letting anyone with the anon key insert
-- their own chat_id here would be a genuine self-granted-access hole. Same
-- pattern already used for coupons: admin.html calls SECURITY DEFINER RPCs,
-- never touches the table directly.

CREATE TABLE IF NOT EXISTS telegram_allowed_users (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id    text UNIQUE NOT NULL,
  label      text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_allowed_users ENABLE ROW LEVEL SECURITY;
-- Intentionally no anon/authenticated policies at all.

CREATE OR REPLACE FUNCTION admin_list_telegram_users()
RETURNS SETOF telegram_allowed_users
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM telegram_allowed_users ORDER BY created_at DESC;
$$;

CREATE OR REPLACE FUNCTION admin_add_telegram_user(p_chat_id text, p_label text)
RETURNS telegram_allowed_users
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r telegram_allowed_users;
BEGIN
  INSERT INTO telegram_allowed_users (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION admin_set_telegram_user_active(p_id uuid, p_active boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE telegram_allowed_users SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_telegram_user(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM telegram_allowed_users WHERE id = p_id;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_telegram_users() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_add_telegram_user(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_set_telegram_user_active(uuid, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_telegram_user(uuid) TO anon, authenticated;

-- Carry over whatever's currently in the old single-value setting.
INSERT INTO telegram_allowed_users (chat_id, label)
SELECT trim(x), 'migrated'
FROM settings, unnest(string_to_array(value, ',')) AS x
WHERE key = 'telegram_authorized_chat_id' AND value IS NOT NULL AND trim(value) != ''
ON CONFLICT (chat_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';
