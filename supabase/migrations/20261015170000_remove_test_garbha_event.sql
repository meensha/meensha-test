-- Remove the duplicate test voucher_event created during this session's
-- kiosk-flow walkthrough — a real "Garbha Santhe" event (created by staff)
-- already exists and should be the only one offered.
DELETE FROM coupons WHERE event_id = 'a0e74637-9fa6-4792-8f1a-a83270c966af';
DELETE FROM voucher_events WHERE id = 'a0e74637-9fa6-4792-8f1a-a83270c966af';
