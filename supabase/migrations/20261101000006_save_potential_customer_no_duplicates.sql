-- Sharing a visiting card to a number that is already a Potential Customer
-- (e.g. they scanned the QR first) used to add a second row. Now the existing
-- row is marked card_shared instead; a new row is only inserted for a number
-- not on the list. Same last-10-digit match register_event_visitor uses.
-- Also records when the card went out and the exact message text sent.
ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS card_message text;
ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS card_shared_at timestamptz;

DROP FUNCTION IF EXISTS public.save_potential_customer(text, text, text, text);
CREATE OR REPLACE FUNCTION public.save_potential_customer(
  p_wa text, p_name text, p_shared_by text, p_region text DEFAULT 'india', p_card_message text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  wa_digits text := regexp_replace(coalesce(p_wa, ''), '[^0-9]', '', 'g');
  region_clean text := CASE WHEN p_region IN ('india','australia') THEN p_region ELSE 'india' END;
BEGIN
  IF region_clean = 'india' AND length(wa_digits) <> 10 THEN
    RAISE EXCEPTION 'A 10-digit WhatsApp number is required';
  END IF;
  IF region_clean = 'australia' AND (length(wa_digits) < 8 OR length(wa_digits) > 15) THEN
    RAISE EXCEPTION 'A WhatsApp number (at least 8 digits) is required';
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'A name is required';
  END IF;
  IF length(trim(p_name)) > 80 OR length(coalesce(p_shared_by,'')) > 40 THEN
    RAISE EXCEPTION 'Name or source too long';
  END IF;

  UPDATE potential_customers
     SET card_shared = true, card_shared_at = now(), card_message = left(p_card_message, 4000)
   WHERE id = (SELECT id FROM potential_customers
                WHERE right(regexp_replace(wa, '[^0-9]', '', 'g'), 10) = right(wa_digits, 10)
                ORDER BY created_at LIMIT 1);
  IF FOUND THEN RETURN true; END IF;

  INSERT INTO potential_customers (wa, name, shared_by, card_shared, region, card_shared_at, card_message)
    VALUES (wa_digits, trim(p_name), COALESCE(p_shared_by, 'unknown'), true, region_clean, now(), left(p_card_message, 4000));
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_potential_customer(text, text, text, text, text) TO anon, authenticated;

-- Merge the one existing duplicate (9845190484): the older scan row keeps
-- its history and becomes card_shared; the extra card-share row is dropped.
UPDATE potential_customers SET card_shared = true WHERE id = '8eb819b4-6c99-40a5-865e-729fabcdb0f4';
DELETE FROM potential_customers WHERE id = 'fcb6ecc8-626a-421b-9de2-cfb92e37d72f'
  AND EXISTS (SELECT 1 FROM potential_customers WHERE id = '8eb819b4-6c99-40a5-865e-729fabcdb0f4');

NOTIFY pgrst, 'reload schema';
