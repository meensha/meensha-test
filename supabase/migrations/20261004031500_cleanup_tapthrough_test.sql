-- Cleanup for the real Telegram tap-through test of the coupon_<code>
-- /start deep link (confirmed working: TAPTEST01 auto-applied, sale was
-- cancelled before confirming so no real sales row was created).
DELETE FROM coupons WHERE code = 'TAPTEST01';
DELETE FROM telegram_allowed_users WHERE chat_id = '1796343031' AND label LIKE 'TEMP%';
