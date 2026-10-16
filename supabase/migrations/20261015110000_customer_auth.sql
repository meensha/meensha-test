-- Customer login (M11) — stage 1 of the build plan (see
-- ~/.claude/plans/stateless-nibbling-scone.md for the full plan).
--
-- Signup: WA number + email + name + password, email verified by a 6-digit
-- OTP before the account is usable. Login: WA number OR email + password,
-- no OTP. Forgot password: email OTP, then set a new password. OTP is
-- delivered by email (free — Resend/Brevo free tier), not WhatsApp (paid,
-- needs a Business API provider) — this whole flow costs nothing to run.
--
-- No customer_id FK gets backfilled onto historical orders/sales — "my
-- orders" is matched by verified WhatsApp number against the existing
-- customer->>'wa' jsonb field already used everywhere (same trust level
-- coupon-locking already relies on), regardless of whether the customer
-- logged in with their WA number or their email. customers.wa stays the
-- account's real identity; email is a second unique identifier + OTP
-- delivery address, not a replacement for it.
--
-- All tables use the same lockdown pattern as orders/telegram_sessions/
-- user_credentials: RLS on, zero anon/authenticated policies. customer_otp
-- and customer_sessions are OTP-hash/session-token tables — touched only by
-- the Edge Functions (via service_role, which bypasses RLS/grants entirely,
-- so no GRANT EXECUTE is needed for the service-role-only functions below).
-- customers holds PII + a password hash so it stays locked down too.

CREATE TABLE IF NOT EXISTS customers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa                 text UNIQUE NOT NULL,  -- canonical form: digits only, country code, e.g. '918709525218'
  email              text UNIQUE NOT NULL,
  name               text,
  password_hash      text NOT NULL,
  email_verified_at  timestamptz,
  created_at         timestamptz DEFAULT now(),
  last_login_at      timestamptz
);
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
-- no policies — only SECURITY DEFINER RPCs touch this

-- purpose ∈ 'signup' | 'reset'. Keyed by email since delivery is always by
-- email now, regardless of which flow the code is for.
CREATE TABLE IF NOT EXISTS customer_otp (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      text NOT NULL,
  purpose    text NOT NULL,
  code_hash  text NOT NULL,
  attempts   int NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_otp_email ON customer_otp(email, purpose, created_at DESC);
ALTER TABLE customer_otp ENABLE ROW LEVEL SECURITY;
-- no policies — service_role only (called from the Edge Functions)

CREATE TABLE IF NOT EXISTS customer_sessions (
  token         text PRIMARY KEY,
  customer_id   uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  wa            text NOT NULL,  -- denormalized so get_my_orders doesn't need a join
  created_at    timestamptz DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  last_seen_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_sessions_customer ON customer_sessions(customer_id);
ALTER TABLE customer_sessions ENABLE ROW LEVEL SECURITY;
-- no policies — service_role + the anon-exposed RPCs below (which never
-- accept a client-supplied wa/customer_id, only an opaque token) touch this

-- ═══════════════════════════════════════════════
-- Signup — service_role only (called from Edge Functions with the
-- service_role key, which bypasses RLS/grants, so these are deliberately
-- NOT granted to anon/authenticated at all).
-- ═══════════════════════════════════════════════

-- Creates (or refreshes, if the previous attempt was never verified) an
-- unverified customer row and returns its id, ready for an OTP to be sent
-- to p_email. Fails if the wa or email already belongs to a *verified*
-- account — an abandoned unverified signup can be retried/overwritten.
CREATE OR REPLACE FUNCTION start_customer_signup(p_wa text, p_email text, p_name text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  existing customers;
BEGIN
  SELECT * INTO existing FROM customers WHERE wa = p_wa OR email = p_email;
  IF existing IS NOT NULL AND existing.email_verified_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error',
      CASE WHEN existing.wa = p_wa THEN 'wa_taken' ELSE 'email_taken' END);
  END IF;

  IF existing IS NOT NULL THEN
    UPDATE customers SET wa = p_wa, email = p_email, name = p_name,
      password_hash = crypt(p_password, gen_salt('bf'))
      WHERE id = existing.id;
  ELSE
    INSERT INTO customers (wa, email, name, password_hash)
      VALUES (p_wa, p_email, p_name, crypt(p_password, gen_salt('bf')));
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION create_customer_otp(p_email text, p_purpose text, p_code text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO customer_otp (email, purpose, code_hash, expires_at)
  VALUES (p_email, p_purpose, crypt(p_code, gen_salt('bf')), now() + interval '10 minutes')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Verifies a 'signup' OTP, marks the account verified, and logs it straight
-- in (returns a session token) — no separate login step right after signup.
CREATE OR REPLACE FUNCTION verify_customer_signup_otp(p_email text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  o customer_otp;
  c customers;
  v_token text;
BEGIN
  SELECT * INTO o FROM customer_otp
    WHERE email = p_email AND purpose = 'signup' AND used_at IS NULL AND expires_at > now() AND attempts < 5
    ORDER BY created_at DESC LIMIT 1;
  IF o IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'expired_or_missing'); END IF;

  IF o.code_hash <> crypt(p_code, o.code_hash) THEN
    UPDATE customer_otp SET attempts = attempts + 1 WHERE id = o.id;
    RETURN jsonb_build_object('ok', false, 'error', 'incorrect_code');
  END IF;
  UPDATE customer_otp SET used_at = now() WHERE id = o.id;

  UPDATE customers SET email_verified_at = now(), last_login_at = now()
    WHERE email = p_email RETURNING * INTO c;
  IF c IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'account_missing'); END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO customer_sessions (token, customer_id, wa, expires_at)
    VALUES (v_token, c.id, c.wa, now() + interval '30 days');

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'customer_id', c.id, 'wa', c.wa, 'email', c.email, 'name', c.name);
END;
$$;

-- ═══════════════════════════════════════════════
-- Login — password-based, no OTP. Anon-callable: only ever verifies a
-- bcrypt hash and returns an opaque session token, never exposes the hash
-- itself, so this carries the same trust level as any password-login RPC.
-- p_identifier is either a WA number (digits) or an email address.
-- ═══════════════════════════════════════════════

CREATE OR REPLACE FUNCTION login_customer(p_identifier text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  c customers;
  v_token text;
BEGIN
  SELECT * INTO c FROM customers WHERE (wa = p_identifier OR email = p_identifier);
  IF c IS NULL OR c.password_hash <> crypt(p_password, c.password_hash) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_credentials');
  END IF;
  IF c.email_verified_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email_not_verified');
  END IF;

  UPDATE customers SET last_login_at = now() WHERE id = c.id;
  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO customer_sessions (token, customer_id, wa, expires_at)
    VALUES (v_token, c.id, c.wa, now() + interval '30 days');

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'customer_id', c.id, 'wa', c.wa, 'email', c.email, 'name', c.name);
END;
$$;
GRANT EXECUTE ON FUNCTION login_customer(text, text) TO anon, authenticated;

-- ═══════════════════════════════════════════════
-- Forgot password — service_role only (Edge Functions send the email).
-- ═══════════════════════════════════════════════

-- Always returns ok:true whether or not the email exists, so this can't be
-- used to enumerate registered emails. Only actually queues an OTP (for the
-- Edge Function to send) when the email is real.
CREATE OR REPLACE FUNCTION request_password_reset(p_email text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM customers WHERE email = p_email);
END;
$$;

CREATE OR REPLACE FUNCTION verify_password_reset(p_email text, p_code text, p_new_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  o customer_otp;
  c customers;
  v_token text;
BEGIN
  SELECT * INTO o FROM customer_otp
    WHERE email = p_email AND purpose = 'reset' AND used_at IS NULL AND expires_at > now() AND attempts < 5
    ORDER BY created_at DESC LIMIT 1;
  IF o IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'expired_or_missing'); END IF;

  IF o.code_hash <> crypt(p_code, o.code_hash) THEN
    UPDATE customer_otp SET attempts = attempts + 1 WHERE id = o.id;
    RETURN jsonb_build_object('ok', false, 'error', 'incorrect_code');
  END IF;
  UPDATE customer_otp SET used_at = now() WHERE id = o.id;

  UPDATE customers SET password_hash = crypt(p_new_password, gen_salt('bf'))
    WHERE email = p_email RETURNING * INTO c;
  IF c IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'account_missing'); END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO customer_sessions (token, customer_id, wa, expires_at)
    VALUES (v_token, c.id, c.wa, now() + interval '30 days');

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'customer_id', c.id, 'wa', c.wa, 'email', c.email, 'name', c.name);
END;
$$;

-- ═══════════════════════════════════════════════
-- Anon-callable — only ever accept an opaque session token, never a
-- client-supplied wa/customer_id, so they can't be used to read/impersonate
-- another customer.
-- ═══════════════════════════════════════════════

CREATE OR REPLACE FUNCTION validate_customer_session(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s customer_sessions; c customers;
BEGIN
  SELECT * INTO s FROM customer_sessions WHERE token = p_token AND expires_at > now();
  IF s IS NULL THEN RETURN NULL; END IF;
  UPDATE customer_sessions SET last_seen_at = now() WHERE token = p_token;
  SELECT * INTO c FROM customers WHERE id = s.customer_id;
  RETURN jsonb_build_object('customer_id', s.customer_id, 'wa', s.wa, 'email', c.email, 'name', c.name);
END;
$$;

-- Payment status: orders.status for anything still pending (not yet 'paid'
-- — a sales row only exists once the Razorpay webhook has already finalized
-- it, so 'paid' orders would just duplicate what's in sales). Shipping
-- status/tracking comes straight from sales' existing admin-entered fields.
CREATE OR REPLACE FUNCTION get_my_orders(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wa text;
BEGIN
  SELECT wa INTO v_wa FROM customer_sessions WHERE token = p_token AND expires_at > now();
  IF v_wa IS NULL THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'pending', (SELECT coalesce(jsonb_agg(o.* ORDER BY o.created_at DESC), '[]'::jsonb)
                FROM orders o WHERE o.customer->>'wa' = v_wa AND o.status <> 'paid'),
    'completed', (SELECT coalesce(jsonb_agg(s.* ORDER BY s.created_at DESC), '[]'::jsonb)
                  FROM sales s WHERE s.customer->>'wa' = v_wa)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION validate_customer_session(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_my_orders(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
