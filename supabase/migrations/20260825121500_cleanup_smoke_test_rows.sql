-- One-off cleanup: removes the __TEST_* rows created while smoke-testing
-- the new submit/approve/reject_purchase_batch RPCs against the live DB
-- this session. inventory_units/inventory_skus for the test were already
-- deleted directly; only the service_role-locked rows (inventory_returns_pending,
-- stock_intake_drafts, purchases, vendor_audit_log) needed this migration.

DELETE FROM inventory_returns_pending WHERE flagged_by = 'test:smoke';
DELETE FROM stock_intake_drafts WHERE submitted_by = 'test:smoke';
DELETE FROM vendor_audit_log WHERE performed_by = 'test:smoke';
DELETE FROM purchases WHERE id = '5b8c7f7a-a408-44d5-a1c0-1ce35a08bfbf';
