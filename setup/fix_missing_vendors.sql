-- ═══════════════════════════════════════════════════════════════
-- MEENSHA — FIX: create missing vendor + auth tables
-- These were skipped in the earlier schema run (inventory_skus/units/offers
-- exist, but vendors and its dependents never got created).
-- Safe to re-run — all IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ───────────────────────────────────────────────────────────────
-- VENDORS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vendors (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id       text UNIQUE NOT NULL,
  name            text NOT NULL,
  wa_number       text,
  place           text,
  gst_number      text,
  address         text,
  notes           text,
  rating          smallint CHECK (rating BETWEEN 1 AND 5),
  status          text NOT NULL DEFAULT 'active',
  first_purchase  date,
  txn_id          uuid UNIQUE NOT NULL DEFAULT gen_random_uuid(),
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_vendors_vid ON vendors(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendors_status ON vendors(status);
CREATE INDEX IF NOT EXISTS idx_vendors_name_trgm ON vendors USING gin(name gin_trgm_ops);

-- ───────────────────────────────────────────────────────────────
-- Per-vendor-per-SKU batch counter
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sku_vendor_batches (
  sku_id        uuid NOT NULL REFERENCES inventory_skus(id) ON DELETE CASCADE,
  vendor_id     text NOT NULL REFERENCES vendors(vendor_id) ON UPDATE CASCADE,
  batch_counter integer NOT NULL DEFAULT 0,
  updated_at    timestamptz DEFAULT now(),
  PRIMARY KEY (sku_id, vendor_id)
);

-- ───────────────────────────────────────────────────────────────
-- Extend purchases with vendor link (in case not already there)
-- ───────────────────────────────────────────────────────────────
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS supplier_inv text;
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS vendor_uuid  uuid REFERENCES vendors(id);
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS vendor_code  text;
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS txn_id       uuid UNIQUE DEFAULT gen_random_uuid();
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS is_migration boolean DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_purch_vendor ON purchases(vendor_uuid);
CREATE INDEX IF NOT EXISTS idx_purch_supplier_inv ON purchases(supplier_inv);

-- ───────────────────────────────────────────────────────────────
-- VENDOR ISSUES
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vendor_issues (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_uuid       uuid NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
  vendor_code       text NOT NULL,
  sku_id            uuid REFERENCES inventory_skus(id),
  batch             text,
  unit_ids          jsonb NOT NULL DEFAULT '[]'::jsonb,
  issue_date        date NOT NULL,
  issue_type        text NOT NULL,
  description       text NOT NULL,
  resolution        text,
  status            text NOT NULL DEFAULT 'open',
  resolved_date     date,
  created_by        text,
  txn_id            uuid UNIQUE NOT NULL DEFAULT gen_random_uuid(),
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_issues_vendor ON vendor_issues(vendor_uuid);
CREATE INDEX IF NOT EXISTS idx_issues_status ON vendor_issues(status);
CREATE INDEX IF NOT EXISTS idx_issues_batch ON vendor_issues(sku_id, batch);

-- ───────────────────────────────────────────────────────────────
-- VENDOR ID EDIT REQUESTS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vendor_edit_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_uuid   uuid NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
  old_vendor_id text NOT NULL,
  new_vendor_id text NOT NULL,
  reason        text,
  requested_by  text,
  status        text NOT NULL DEFAULT 'pending',
  reviewed_by   text,
  reviewed_at   timestamptz,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ver_status ON vendor_edit_requests(status);

-- ───────────────────────────────────────────────────────────────
-- VENDOR AUDIT LOG
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vendor_audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_uuid   uuid NOT NULL,
  action        text NOT NULL,
  old_value     text,
  new_value     text,
  units_affected integer DEFAULT 0,
  performed_by  text,
  created_at    timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- RPCs (create/replace so they're consistent even if some existed)
-- ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION next_vendor_id()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE next_num integer; vid text;
BEGIN
  SELECT COALESCE(MAX(CAST(vendor_id AS integer)), 0) + 1
    INTO next_num FROM vendors WHERE vendor_id ~ '^[0-9]+$';
  vid := LPAD(next_num::text, 3, '0');
  RETURN vid;
END;$$;

CREATE OR REPLACE FUNCTION create_batch_units(
  p_sku_id       uuid,
  p_vendor_code  text,
  p_purchase_id  uuid,
  p_qty          integer,
  p_photo_urls   text[]
)
RETURNS TABLE(batch text, unit_code text, unit_id uuid)
LANGUAGE plpgsql AS $$
DECLARE
  v_counter integer; v_batch text; v_sku_code text;
  v_unit_code text; v_unit_id uuid; i integer; v_photo text;
BEGIN
  INSERT INTO sku_vendor_batches(sku_id, vendor_id, batch_counter)
       VALUES (p_sku_id, p_vendor_code, 1)
  ON CONFLICT (sku_id, vendor_id)
  DO UPDATE SET batch_counter = sku_vendor_batches.batch_counter + 1, updated_at = now()
  RETURNING batch_counter INTO v_counter;
  v_batch := LPAD(v_counter::text, 2, '0');
  SELECT sku_code INTO v_sku_code FROM inventory_skus WHERE id = p_sku_id;
  FOR i IN 1..p_qty LOOP
    v_unit_code := v_sku_code || '-' || p_vendor_code || v_batch || '/' || LPAD(i::text, 2, '0');
    v_photo := CASE WHEN array_length(p_photo_urls,1) >= i THEN p_photo_urls[i] ELSE NULL END;
    INSERT INTO inventory_units(unit_code, sku_id, purchase_id, vendor_code, batch, unit_num, photo_url)
         VALUES (v_unit_code, p_sku_id, p_purchase_id, p_vendor_code, v_batch, i, v_photo)
      RETURNING id INTO v_unit_id;
    batch := v_batch; unit_code := v_unit_code; unit_id := v_unit_id;
    RETURN NEXT;
  END LOOP;
END;$$;

CREATE OR REPLACE FUNCTION change_vendor_id(
  p_vendor_uuid uuid, p_new_vid text, p_performed_by text
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_old_vid text; v_rec record; v_units_changed integer := 0;
BEGIN
  SELECT vendor_id INTO v_old_vid FROM vendors WHERE id = p_vendor_uuid;
  IF v_old_vid IS NULL THEN RAISE EXCEPTION 'Vendor not found'; END IF;
  IF EXISTS (SELECT 1 FROM vendors WHERE vendor_id = p_new_vid AND id <> p_vendor_uuid) THEN
    RAISE EXCEPTION 'Vendor id % already in use', p_new_vid;
  END IF;
  UPDATE vendors SET vendor_id = p_new_vid, updated_at = now() WHERE id = p_vendor_uuid;
  UPDATE purchases     SET vendor_code = p_new_vid WHERE vendor_uuid = p_vendor_uuid;
  UPDATE vendor_issues SET vendor_code = p_new_vid WHERE vendor_uuid = p_vendor_uuid;
  FOR v_rec IN
    SELECT u.id, u.batch, u.unit_num, s.sku_code
      FROM inventory_units u JOIN inventory_skus s ON s.id = u.sku_id
     WHERE u.vendor_code = v_old_vid
  LOOP
    UPDATE inventory_units
       SET unit_code = v_rec.sku_code || '-' || p_new_vid || v_rec.batch || '/' || LPAD(v_rec.unit_num::text, 2, '0'),
           vendor_code = p_new_vid, updated_at = now()
     WHERE id = v_rec.id;
    v_units_changed := v_units_changed + 1;
  END LOOP;
  INSERT INTO vendor_audit_log(vendor_uuid, action, old_value, new_value, units_affected, performed_by)
       VALUES (p_vendor_uuid, 'id_change', v_old_vid, p_new_vid, v_units_changed, p_performed_by);
  RETURN v_units_changed;
END;$$;

-- ───────────────────────────────────────────────────────────────
-- RLS
-- ───────────────────────────────────────────────────────────────
ALTER TABLE vendors              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sku_vendor_batches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_issues        ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_edit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_audit_log     ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'vendors','sku_vendor_batches','vendor_issues','vendor_edit_requests','vendor_audit_log'
  ]) LOOP
    EXECUTE format('DROP POLICY IF EXISTS "all_anon" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_anon" ON %I FOR ALL TO anon USING (true) WITH CHECK (true);', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_auth" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_auth" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true);', t);
  END LOOP;
END$$;

-- ───────────────────────────────────────────────────────────────
-- Force PostgREST to pick up the new tables immediately
-- ───────────────────────────────────────────────────────────────
NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
-- VERIFY:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public' AND table_name='vendors';
-- ═══════════════════════════════════════════════════════════════
