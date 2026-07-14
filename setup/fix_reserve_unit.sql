-- The deployed reserve_unit() was setting status='reserved' but never setting
-- reserved_until, so abandoned cart holds would never expire via
-- release_expired_reservations(). Re-create both correctly.
-- (Drop first: the deployed versions have a different signature/return type
-- than what we're installing, and CREATE OR REPLACE can't change those.)

DROP FUNCTION IF EXISTS reserve_unit(uuid);
DROP FUNCTION IF EXISTS reserve_unit(uuid, integer);
DROP FUNCTION IF EXISTS release_expired_reservations();
DROP FUNCTION IF EXISTS unreserve_unit(uuid);

CREATE OR REPLACE FUNCTION reserve_unit(p_unit_id uuid, p_minutes integer DEFAULT 15)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE rows_affected integer;
BEGIN
  UPDATE inventory_units
     SET status = 'reserved',
         reserved_until = now() + (p_minutes || ' minutes')::interval,
         updated_at = now()
   WHERE id = p_unit_id AND status = 'available';
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected > 0;
END;$$;

CREATE OR REPLACE FUNCTION release_expired_reservations()
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE rows_affected integer;
BEGIN
  UPDATE inventory_units
     SET status = 'available', reserved_until = NULL, updated_at = now()
   WHERE status = 'reserved' AND reserved_until < now();
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected;
END;$$;

-- Also add an explicit unreserve (cart item removed / released early)
CREATE OR REPLACE FUNCTION unreserve_unit(p_unit_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE rows_affected integer;
BEGIN
  UPDATE inventory_units
     SET status = 'available', reserved_until = NULL, updated_at = now()
   WHERE id = p_unit_id AND status = 'reserved';
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected > 0;
END;$$;

NOTIFY pgrst, 'reload schema';
