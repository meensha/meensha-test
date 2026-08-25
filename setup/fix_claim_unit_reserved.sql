-- CRITICAL FIX: the live claim_unit function only matched status='available',
-- silently failing to convert 'reserved' units to 'sold' — despite
-- schema_combined.sql saying it should handle both. Confirmed by black-box
-- testing (2026-08-25): claim_unit returns true and works on an 'available'
-- unit, but returns false (0 rows affected) on a 'reserved' one.
--
-- Real-world impact: the storefront cart ALWAYS reserves a unit (15-minute
-- hold) before checkout, so every completed online Razorpay sale was
-- failing to mark its unit sold — and after the 15-minute hold expired,
-- release_expired_reservations would flip it back to 'available',
-- creating a real risk of the same physical saree being sold twice.
--
-- This CREATE OR REPLACE is idempotent and safe to run even if the live
-- function already matches this (in case drift was somewhere else) — it
-- just guarantees the WHERE clause is correct going forward.

CREATE OR REPLACE FUNCTION claim_unit(p_unit_id uuid, p_sale_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE rows_affected integer;
BEGIN
  UPDATE inventory_units
     SET status = 'sold', sold_in_sale_id = p_sale_id,
         reserved_until = NULL, updated_at = now()
   WHERE id = p_unit_id AND status IN ('available','reserved');
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected > 0;
END;$$;

NOTIFY pgrst, 'reload schema';
