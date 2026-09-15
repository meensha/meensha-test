-- One-off data correction: sale 7e08da5d-fca3-4f0e-8c95-daf3593f6fb8 (2026-08-30)
-- was recorded with total=1870, paid=1200, leaving balance=670 due.
-- The customer's payment of 1200 was final — the 670 gap was an
-- unrecorded extra discount, not an unpaid balance. Lowering total to
-- match paid so the invoice PDF's existing "Additional Discount" gap
-- detection (generate-invoice-pdf/index.ts) shows it correctly instead
-- of a false Balance Due.

UPDATE sales
SET total = 1200,
    balance = 0,
    notes = 'Extra discount of 670 (corrected from balance-due 2026-09-15)'
WHERE id = '7e08da5d-fca3-4f0e-8c95-daf3593f6fb8'
  AND total = 1870 AND paid = 1200 AND balance = 670;
