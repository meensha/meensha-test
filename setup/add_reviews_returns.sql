-- Verified-purchase reviews + per-order returns (see
-- ~/.claude/plans/stateless-nibbling-scone.md for the full plan). Depends on
-- add_customer_auth.sql having already been run (customer_sessions table).
--
-- Reviews stay order-level, not per-SKU: `sales` has no line-item table
-- (items is embedded jsonb), so a review targets a whole delivered order,
-- with an optional jsonb snapshot of which item it's about.

ALTER TABLE reviews ADD COLUMN IF NOT EXISTS photo_url_2 text;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS sale_id uuid REFERENCES sales(id);
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS item_snapshot jsonb;

ALTER TABLE sales ADD COLUMN IF NOT EXISTS return_status text;
ALTER TABLE sales ADD COLUMN IF NOT EXISTS return_activated_at timestamptz;
ALTER TABLE sales ADD COLUMN IF NOT EXISTS return_activated_by text;
ALTER TABLE sales ADD COLUMN IF NOT EXISTS return_notes text;

CREATE TABLE IF NOT EXISTS sales_return_log (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_id    uuid NOT NULL REFERENCES sales(id),
  action     text NOT NULL,
  "by"       text,
  at         timestamptz DEFAULT now(),
  notes      text
);
ALTER TABLE sales_return_log ENABLE ROW LEVEL SECURITY;
-- no anon/authenticated policies — admin.html writes this via the anon key
-- today the same way it writes `sales` itself (no RLS lockdown on `sales`
-- either, a pre-existing gap flagged in the M11 plan, not fixed here).

-- ═══════════════════════════════════════════════
-- submit_review — anon-callable, but only ever resolves the customer's wa
-- server-side from their session token, and only accepts a sale_id that
-- actually belongs to that wa AND is delivered (or was a non-shipped,
-- i.e. in-person, sale). Mirrors get_my_orders's trust model exactly.
-- ═══════════════════════════════════════════════
CREATE OR REPLACE FUNCTION submit_review(
  p_token text,
  p_sale_id uuid,
  p_item_snapshot jsonb,
  p_rating smallint,
  p_review_text text,
  p_photo_url text DEFAULT NULL,
  p_photo_url_2 text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wa text;
  v_name text;
  v_sale sales;
BEGIN
  SELECT cs.wa, c.name INTO v_wa, v_name
    FROM customer_sessions cs JOIN customers c ON c.id = cs.customer_id
    WHERE cs.token = p_token AND cs.expires_at > now();
  IF v_wa IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_logged_in');
  END IF;

  SELECT * INTO v_sale FROM sales
    WHERE id = p_sale_id AND customer->>'wa' = v_wa
      AND (shipping_status = 'delivered' OR delivery_mode IS DISTINCT FROM 'shipping');
  IF v_sale IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_eligible');
  END IF;

  INSERT INTO reviews (wa, display_name, invoice_ref, sale_id, item_snapshot, rating, review_text, photo_url, photo_url_2, status)
    VALUES (v_wa, v_name, v_sale.inv, p_sale_id, p_item_snapshot, p_rating, p_review_text, p_photo_url, p_photo_url_2, 'pending');

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_review(text, uuid, jsonb, smallint, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
