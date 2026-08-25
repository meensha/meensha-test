-- Widens stock_intake_drafts to support multi-item vendor purchases (India
-- Enter Inventory, via the Telegram bot), on top of its existing single-item
-- use by the AU bot's Stock Intake flow. Purely additive: new nullable
-- columns only, existing submit_stock_intake_draft / admin_approve_stock_intake_draft
-- / admin_reject_stock_intake_draft RPCs are untouched and keep working
-- exactly as today for AU (each of those single-item submissions just
-- becomes a "batch of one" via the new batch_id default).

ALTER TABLE stock_intake_drafts
  ADD COLUMN IF NOT EXISTS vendor_uuid   uuid REFERENCES vendors(id),
  ADD COLUMN IF NOT EXISTS batch_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS payment       jsonb,
  ADD COLUMN IF NOT EXISTS is_defective  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS defect_qty    integer,
  ADD COLUMN IF NOT EXISTS defect_reason text;

CREATE INDEX IF NOT EXISTS stock_intake_drafts_batch_id_idx ON stock_intake_drafts (batch_id);

-- Where flagged-defective items land on approval — never inventory_units,
-- so a faulty piece can't structurally become sellable stock.
CREATE TABLE IF NOT EXISTS inventory_returns_pending (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_id       uuid REFERENCES inventory_skus(id),
  purchase_id  uuid REFERENCES purchases(id),
  vendor_uuid  uuid REFERENCES vendors(id),
  qty          integer NOT NULL,
  reason       text,
  photo_url    text,
  flagged_at   timestamptz DEFAULT now(),
  flagged_by   text,
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent_to_vendor')),
  resolved_at  timestamptz
);
ALTER TABLE inventory_returns_pending ENABLE ROW LEVEL SECURITY;
-- No policies — service_role only (Edge Functions), same lockdown pattern
-- as telegram_sessions / stock_intake_drafts.

ALTER TABLE vendors ADD COLUMN IF NOT EXISTS company_name text;

NOTIFY pgrst, 'reload schema';
