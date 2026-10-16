-- Lightweight capture for "share my visiting card" from the kiosk sidebar
-- when no sale is in progress: just a WhatsApp number + name, nothing like
-- the full `customers` auth table (which requires email+password and is for
-- storefront login, not this). Not linked to that table -- a separate,
-- much simpler contacts record.
CREATE TABLE IF NOT EXISTS visiting_card_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wa text NOT NULL,
  name text NOT NULL,
  shared_by text NOT NULL,       -- username of the staff member who shared, e.g. 'shalini'
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE visiting_card_shares ENABLE ROW LEVEL SECURITY;

-- Anon-callable (same pattern as register_event_visitor): staff share this
-- from an authenticated kiosk session, but the RPC itself only needs basic
-- input validation, not a privileged check -- it just appends a row.
CREATE OR REPLACE FUNCTION public.save_visiting_card_share(p_wa text, p_name text, p_shared_by text)
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
  INSERT INTO visiting_card_shares (wa, name, shared_by)
    VALUES (wa_digits, trim(p_name), COALESCE(p_shared_by, 'unknown'));
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_visiting_card_share(text, text, text) TO anon, authenticated;
