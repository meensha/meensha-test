ALTER TABLE sales ADD COLUMN IF NOT EXISTS razorpay_fee numeric NOT NULL DEFAULT 0;
NOTIFY pgrst, 'reload schema';
