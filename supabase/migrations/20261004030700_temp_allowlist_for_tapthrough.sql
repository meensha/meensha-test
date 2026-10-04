-- Temporary: allowlist Dheeraj's own chat_id so he can do a real Telegram
-- tap-through test of the coupon_<code> /start deep link. Removed by a
-- follow-up migration immediately after the test.
INSERT INTO telegram_allowed_users (chat_id, label, active)
VALUES ('1796343031', 'TEMP - tap-through test, remove after', true)
ON CONFLICT (chat_id) DO UPDATE SET active = true;
