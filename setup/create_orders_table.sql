-- Tracks online-checkout lifecycle (storefront cart -> Razorpay Payment Link -> paid).
-- Separate from `sales` (which stays the record of *completed* revenue, exactly as
-- M6 already built it). Only the create-payment-link / razorpay-webhook Edge
-- Functions touch this table (via the service_role key) — no anon RLS policy is
-- added on purpose, so it stays inaccessible to the public anon key.

CREATE TABLE IF NOT EXISTS orders (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now(),
  customer              jsonb NOT NULL,
  items                 jsonb NOT NULL,
  total                 numeric NOT NULL,
  currency              text NOT NULL DEFAULT 'INR',
  unit_ids              uuid[] NOT NULL DEFAULT '{}',
  razorpay_payment_link_id text,
  razorpay_short_url    text,
  status                text NOT NULL DEFAULT 'created'  -- created | paid | expired | cancelled
);

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_rzp_link ON orders(razorpay_payment_link_id);

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
-- Intentionally no policies: anon/authenticated get zero access by default.
-- The Edge Functions use the service_role key, which bypasses RLS entirely.

NOTIFY pgrst, 'reload schema';
