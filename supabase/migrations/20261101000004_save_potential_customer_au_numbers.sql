-- India numbers stay strictly 10 digits; Australian numbers have no fixed
-- length enforced (just non-empty, max 15 digits per E.164). Otherwise
-- identical to 20261101000000's body.
CREATE OR REPLACE FUNCTION public.save_potential_customer(p_wa text, p_name text, p_shared_by text, p_region text DEFAULT 'india')
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
  INSERT INTO potential_customers (wa, name, shared_by, card_shared, region)
    VALUES (wa_digits, trim(p_name), COALESCE(p_shared_by, 'unknown'), true, region_clean);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_potential_customer(text, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
