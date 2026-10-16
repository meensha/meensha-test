-- Renamed per follow-up instruction: this is a lightweight potential-
-- customer/lead tracker, not just a one-off "card shared" log. Adds the
-- requested tracking columns.
ALTER TABLE visiting_card_shares RENAME TO potential_customers;

ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS purchases_so_far numeric NOT NULL DEFAULT 0;
ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS requests text;
ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS card_shared boolean NOT NULL DEFAULT true;
ALTER TABLE potential_customers ADD COLUMN IF NOT EXISTS follow_up text;

DROP FUNCTION IF EXISTS public.save_visiting_card_share(text, text, text);

CREATE OR REPLACE FUNCTION public.save_potential_customer(p_wa text, p_name text, p_shared_by text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE wa_digits text := regexp_replace(p_wa, '[^0-9]', '', 'g');
BEGIN
  IF length(wa_digits) <> 10 THEN
    RAISE EXCEPTION 'A 10-digit WhatsApp number is required';
  END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'A name is required';
  END IF;
  INSERT INTO potential_customers (wa, name, shared_by, card_shared)
    VALUES (wa_digits, trim(p_name), COALESCE(p_shared_by, 'unknown'), true);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_potential_customer(text, text, text) TO anon, authenticated;
