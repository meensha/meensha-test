-- Cleanup for the live verification test of the create-payment-link
-- price-tampering fix (confirmed: real price INR 18,250 was correctly used
-- despite a tampered total:1 in the request). Removes the test order row;
-- the unpaid Razorpay test link itself is harmless and will go stale.
DELETE FROM orders WHERE id = '0d5bb893-67ca-4af0-999d-82e1fac6075a';
