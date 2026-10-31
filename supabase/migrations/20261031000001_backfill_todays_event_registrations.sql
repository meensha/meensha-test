-- One-time backfill, paired with 20261031000000: that migration only makes
-- *new* register_event_visitor() calls feed potential_customers -- it does
-- nothing for people who already scanned the offer QR earlier today, before
-- the fix went live. Pulls today's (Asia/Kolkata) coupons rows with
-- source='event_registration' into potential_customers, same shape and dedup
-- rule (last-10-digits WhatsApp match) as the live function now uses.
-- Idempotent: safe to re-run, skips anyone already present.

INSERT INTO potential_customers (wa, name, shared_by, card_shared, requests, created_at)
SELECT DISTINCT ON (right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10))
       c.customer_wa, c.customer_name, 'Scan: ' || ve.title, false,
       'Registered via scan-for-offer QR (' || ve.title || ')', c.created_at
FROM coupons c
JOIN voucher_events ve ON ve.id = c.event_id
WHERE c.source = 'event_registration'
  AND c.created_at >= (date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata')
  AND NOT EXISTS (
    SELECT 1 FROM potential_customers pc
    WHERE right(regexp_replace(pc.wa, '[^0-9]', '', 'g'), 10)
        = right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10)
  )
ORDER BY right(regexp_replace(c.customer_wa, '[^0-9]', '', 'g'), 10), c.created_at ASC;
