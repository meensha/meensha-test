-- Lets the Razorpay webhook mark the coupon used once payment is confirmed.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS coupon jsonb;

NOTIFY pgrst, 'reload schema';
