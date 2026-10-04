-- Temporary: one throwaway single-use public coupon for a real Telegram
-- tap-through test of the coupon_<code> /start deep link (India bot).
-- Deleted by a follow-up migration immediately after the test.
INSERT INTO coupons (code, discount_type, discount_value, region, single_use, active)
VALUES ('TAPTEST01', 'flat', 1, 'india', true, true)
ON CONFLICT (code) DO NOTHING;
