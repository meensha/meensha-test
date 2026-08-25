-- Lets create-payment-link/razorpay-webhook know an order came from the
-- Telegram kiosk bot (not the storefront) and which staff chat to notify
-- once the payment actually lands.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS source text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS telegram_chat_id bigint;

NOTIFY pgrst, 'reload schema';
