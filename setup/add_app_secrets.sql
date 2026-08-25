-- Write-only secret storage for values admin.html needs to let staff submit
-- (e.g. the Instagram access token) but must NEVER be readable through the
-- anon key — unlike `settings`, which is fully open anon RLS and fine for
-- non-sensitive config, but wrong for anything that grants real access
-- (posting to Instagram, etc.). Same lockdown pattern as orders/
-- customer_otp/telegram_sessions: RLS on, zero anon/authenticated policies,
-- touched only by SECURITY DEFINER RPCs (write) and Edge Functions via
-- service_role (read).
CREATE TABLE IF NOT EXISTS app_secrets (
  key         text PRIMARY KEY,
  value       text,
  updated_at  timestamptz DEFAULT now()
);
ALTER TABLE app_secrets ENABLE ROW LEVEL SECURITY;
-- no policies — RPC + service_role only

-- Sets a secret. Deliberately RETURNS void — never echoes the value back,
-- so even the admin's own browser network tab doesn't show it was accepted
-- by seeing it reflected in a response.
CREATE OR REPLACE FUNCTION admin_set_secret(p_key text, p_value text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO app_secrets (key, value, updated_at) VALUES (p_key, p_value, now())
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now();
END;
$$;
GRANT EXECUTE ON FUNCTION admin_set_secret(text, text) TO anon, authenticated;

-- Status-only check for the dashboard reminder card — tells the UI whether
-- a key is set, without ever returning the value itself.
CREATE OR REPLACE FUNCTION admin_secret_is_set(p_key text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM app_secrets WHERE key = p_key AND value IS NOT NULL AND value <> '');
END;
$$;
GRANT EXECUTE ON FUNCTION admin_secret_is_set(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
