-- Remove the original 3-argument register_event_visitor(uuid, text, text)
-- from setup/add_voucher_events.sql. No migration ever dropped it, so it is
-- still anon-callable in production and BYPASSES the hardening: no rate limit,
-- no server-side Instagram handle requirement or validation, no length caps.
-- It also makes a 3-field RPC body ambiguous (PGRST203) against the 5-arg
-- function. Only register.html calls this RPC, always with the 5-arg form.

DROP FUNCTION IF EXISTS register_event_visitor(uuid, text, text);

NOTIFY pgrst, 'reload schema';
