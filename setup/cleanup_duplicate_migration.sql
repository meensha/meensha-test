-- ═══════════════════════════════════════════════════════════════
-- CLEANUP: undo the migration that ran against duplicated legacy
-- inventory rows (accidental reseed during the 2026-07-12 project
-- restart), then de-duplicate the legacy `inventory` table, so the
-- migration can be re-run cleanly.
-- ═══════════════════════════════════════════════════════════════

-- 1) Undo the migration output (all of it was created just now, safe to wipe)
DELETE FROM inventory_units;
DELETE FROM sku_vendor_batches;
DELETE FROM inventory_skus;
DELETE FROM purchases WHERE is_migration = true;

-- 2) De-duplicate legacy inventory: keep the earliest row per item_id
WITH ranked AS (
  SELECT id, item_id,
         ROW_NUMBER() OVER (PARTITION BY item_id ORDER BY created_at ASC, id ASC) AS rn
  FROM inventory
)
DELETE FROM inventory
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
-- VERIFY (run separately, should show 0 dupes and original row count):
--   SELECT item_id, COUNT(*) FROM inventory GROUP BY item_id HAVING COUNT(*) > 1;
--   SELECT COUNT(*) FROM inventory;
--   SELECT COUNT(*) FROM inventory_skus;   -- should be 0
-- ═══════════════════════════════════════════════════════════════
