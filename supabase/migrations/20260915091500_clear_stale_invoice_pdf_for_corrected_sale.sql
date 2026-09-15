-- generate-invoice-pdf short-circuits and returns the existing PDF link
-- whenever sales.invoice_pdf_path is already set — so after correcting
-- this sale's total/balance in the prior migration, the already-generated
-- MSH-1040.pdf is now stale (still shows the old total/balance). Clearing
-- the path here lets the next generate-invoice-pdf call regenerate it
-- from the corrected row and upsert over the same storage path.

UPDATE sales
SET invoice_pdf_path = NULL
WHERE id = '7e08da5d-fca3-4f0e-8c95-daf3593f6fb8'
  AND total = 1200 AND paid = 1200 AND balance = 0;
