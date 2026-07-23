-- Customer login (M11) — stage 1 of the build plan (see
-- ~/.claude/plans/stateless-nibbling-scone.md for the full plan). WhatsApp
-- OTP login + "My Account" order/payment/shipping visibility.
--
-- No customer_id FK gets backfilled onto historical orders/sales — "my
-- orders" is matched by verified WhatsApp number against the existing
-- customer->>'wa' jsonb field already used everywhere (same trust level
-- coupon-locking already relies on). customers exists to anchor OTP login
-- and sessions, not as the join key for orders.
--
-- All three tables use the same lockdown pattern as orders/telegram_sessions/
-- user_credentials: RLS on, zero anon/authenticated policies. customer_otp
-- and customer_sessions are OTP-hash/session-token tables — touched only by
-- the two Edge Functions (via service_role, which bypasses RLS/grants
-- entirely, so no GRANT EXECUTE is needed for the service-role-only
-- functions below). customers holds PII (name+WA) so it stays locked down
-- too, even though it's less sensitive than the other two.

CREATE TABLE IF NOT EXISTS customers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa            text UNIQUE NOT NULL,  -- canonical form: digits only, country code, e.g. '918709525218'
  name          text,
  created_at    timestamptz DEFAULT now(),
  last_login_at timestamptz
);
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
-- no policies — only SECURITY DEFINER RPCs touch this

CREATE TABLE IF NOT EXISTS customer_otp (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa         text NOT NULL,
  code_hash  text NOT NULL,
  attempts   int NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_otp_wa ON customer_otp(wa, created_at DESC);
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
-- no policies — service_role + the two anon-exposed RPCs below (which never
-- accept a client-supplied wa/customer_id, only an opaque token) touch this

-- ═══════════════════════════════════════════════
-- OTP send/verify — service_role only (called from the Edge Functions with
-- the service_role key, which bypasses RLS/grants, so these are
-- deliberately NOT granted to anon/authenticated at all).
-- ═══════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_customer_otp(p_wa text, p_code text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO customer_otp (wa, code_hash, expires_at)
  VALUES (p_wa, crypt(p_code, gen_salt('bf')), now() + interval '5 minutes')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Returns {token, customer_id, wa, name} on a correct code, or NULL on a
-- wrong/expired/already-used one (still increments attempts on a wrong
-- code so a 6-digit code can't be brute-forced within its 5-minute window).
CREATE OR REPLACE FUNCTION verify_customer_otp_code(p_wa text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  o customer_otp;
  c customers;
  v_token text;
BEGIN
  SELECT * INTO o FROM customer_otp
    WHERE wa = p_wa AND used_at IS NULL AND expires_at > now() AND attempts < 5
    ORDER BY created_at DESC LIMIT 1;
  IF o IS NULL THEN RETURN NULL; END IF;

  IF o.code_hash <> crypt(p_code, o.code_hash) THEN
    UPDATE customer_otp SET attempts = attempts + 1 WHERE id = o.id;
    RETURN NULL;
  END IF;

  UPDATE customer_otp SET used_at = now() WHERE id = o.id;

  INSERT INTO customers (wa) VALUES (p_wa)
    ON CONFLICT (wa) DO UPDATE SET last_login_at = now()
    RETURNING * INTO c;

  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO customer_sessions (token, customer_id, wa, expires_at)
    VALUES (v_token, c.id, p_wa, now() + interval '30 days');

  RETURN jsonb_build_object('token', v_token, 'customer_id', c.id, 'wa', c.wa, 'name', c.name);
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
  RETURN jsonb_build_object('customer_id', s.customer_id, 'wa', s.wa, 'name', c.name);
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
