-- Closes the gap the 2026-11-01 security review found: the region split
-- added by 20261101000000 was purely a client-side query filter -- the
-- table's RLS policies (20261016170000) still granted unconditional
-- read/write to anyone holding the public anon key, so a direct REST call
-- (?region=eq.india, bypassing the kiosk UI) could read or write any
-- region's leads regardless of who -- if anyone -- was logged in.
--
-- Fix reuses require_admin_session() (20260927180000), the same session
-- mechanism every admin_* RPC already trusts: kiosk.html sends the logged-in
-- staff member's token as the x-admin-session header on every call to this
-- table (sbGet/sbPatch/the raw DELETE in deletePotentialCustomer), so RLS
-- can now check it directly instead of trusting the client's own filter.
--   - No valid session -> require_admin_session() raises -> request denied.
--   - service_role (edge functions, pg_cron) -> unrestricted, matching
--     require_admin_session()'s existing bypass.
--   - Locked staff (shalini/meenakshi, users.region set) -> only rows for
--     their own region.
--   - Unlocked staff (shameen, users.region NULL) -> unrestricted, same as
--     the India/Australia/All toggle already gives them client-side.
-- The two anon-callable write RPCs (save_potential_customer,
-- register_event_visitor) are SECURITY DEFINER owned by the table owner, so
-- their internal INSERTs bypass RLS as before -- this only locks down
-- direct REST access, which is exactly the gap that was found.

CREATE OR REPLACE FUNCTION public.potential_customers_region_allowed(p_region text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users;
BEGIN
  u := require_admin_session();
  IF u.id IS NULL THEN RETURN true; END IF;  -- service_role / direct DB callers
  IF u.region IS NULL THEN RETURN true; END IF;  -- shameen: unrestricted
  RETURN u.region = p_region;
END;
$$;
GRANT EXECUTE ON FUNCTION public.potential_customers_region_allowed(text) TO anon, authenticated;

DROP POLICY IF EXISTS "all_anon" ON potential_customers;
DROP POLICY IF EXISTS "all_auth" ON potential_customers;

CREATE POLICY "region_scoped" ON potential_customers FOR ALL
  TO anon, authenticated
  USING (potential_customers_region_allowed(region))
  WITH CHECK (potential_customers_region_allowed(region));

NOTIFY pgrst, 'reload schema';
