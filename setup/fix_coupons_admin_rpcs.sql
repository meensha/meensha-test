-- Fix: admin.html's shared request helper always sends
-- "Prefer: return=representation", which makes Postgres require a SELECT
-- policy to return the affected row on INSERT/UPDATE/DELETE — even though the
-- write itself would otherwise be allowed. Since coupons intentionally has no
-- anon SELECT policy (same anon key is used by the public storefront, and we
-- don't want it able to enumerate codes/customer WA numbers), every direct
-- write from admin.html was failing with 42501.
--
-- Fix: route admin's create/toggle/delete through SECURITY DEFINER RPCs
-- instead (same pattern as admin_list_coupons/validate_coupon/consume_coupon),
-- and drop the now-unnecessary (and, since anyone can call them with the same
-- anon key, unsafe) direct write policies.

DROP POLICY IF EXISTS "coupons_anon_write" ON coupons;
DROP POLICY IF EXISTS "coupons_anon_update" ON coupons;
DROP POLICY IF EXISTS "coupons_anon_delete" ON coupons;

CREATE OR REPLACE FUNCTION admin_create_coupon(
  p_code text, p_customer_name text, p_customer_wa text,
  p_discount_type text, p_discount_value numeric, p_region text,
  p_valid_from date, p_valid_until date
)
RETURNS coupons
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c coupons;
BEGIN
  INSERT INTO coupons(code, customer_name, customer_wa, discount_type, discount_value, region, valid_from, valid_until)
  VALUES (upper(trim(p_code)), p_customer_name, p_customer_wa, p_discount_type, p_discount_value, p_region, p_valid_from, p_valid_until)
  RETURNING * INTO c;
  RETURN c;
END;
$$;

CREATE OR REPLACE FUNCTION admin_set_coupon_active(p_id uuid, p_active boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE coupons SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_coupon(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM coupons WHERE id = p_id;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_create_coupon(text,text,text,text,numeric,text,date,date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_set_coupon_active(uuid,boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_coupon(uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
