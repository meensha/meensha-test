-- inventory_returns_pending needs two more things now that admin.html is
-- wiring against it directly (not just the approve RPC):
--   1. unit_ids uuid[] — links a return to specific already-existing units
--      (the "flag a piece defective after the fact" path from the Inventory/
--      Vendor Units screen). Intake-time defects (flagged during Approve,
--      before any unit ever existed) leave this null — nothing to link.
--   2. Permissive RLS — same pattern as the rest of the app's operational
--      tables (purchases, inventory_units, vendor_issues): admin.html reads
--      and writes these directly with the anon key, not through an RPC.

ALTER TABLE inventory_returns_pending ADD COLUMN IF NOT EXISTS unit_ids uuid[];

DROP POLICY IF EXISTS "all_anon" ON inventory_returns_pending;
CREATE POLICY "all_anon" ON inventory_returns_pending FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON inventory_returns_pending;
CREATE POLICY "all_auth" ON inventory_returns_pending FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
