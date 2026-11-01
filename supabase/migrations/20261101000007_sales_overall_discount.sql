-- Kiosk "overall discount": a flat amount taken off the whole bill (after any
-- per-item coupons), shown as its own line on the invoice. 0 = none.
ALTER TABLE sales ADD COLUMN IF NOT EXISTS overall_discount numeric NOT NULL DEFAULT 0 CHECK (overall_discount >= 0);
NOTIFY pgrst, 'reload schema';
