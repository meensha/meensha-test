-- Removes the __TEST__-prefixed rows created while smoke-testing the new
-- purchase-intake-batch RPCs (submit/approve/reject) against the live DB.
-- One-off cleanup, not a schema change.

DELETE FROM inventory_units WHERE sku_id IN (
  SELECT id FROM inventory_skus WHERE name LIKE '\_\_TEST\_%' ESCAPE '\'
);
DELETE FROM inventory_returns_pending WHERE flagged_by = 'test:smoke';
DELETE FROM inventory_skus WHERE name LIKE '\_\_TEST\_%' ESCAPE '\';
DELETE FROM vendor_audit_log WHERE performed_by = 'test:smoke';
DELETE FROM purchases WHERE id = '22b97e97-f918-44aa-98b9-810b58b2f581';
DELETE FROM stock_intake_drafts WHERE submitted_by = 'test:smoke';
