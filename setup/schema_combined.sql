-- ═══════════════════════════════════════════════════════════════
-- MEENSHA — COMBINED SCHEMA (run once in Supabase SQL Editor)
-- Paste this entire file. Safe to re-run — uses IF NOT EXISTS everywhere.
-- Order: Base tables → M1 additions → Auth tables → User seeds
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ───────────────────────────────────────────────────────────────
-- BASE: INVENTORY (legacy flat table — kept for migration button)
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inventory (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id     text UNIQUE,
  cat         text,
  name        text,
  subtype     text,
  fabric      text,
  qty         integer DEFAULT 0,
  sold        integer DEFAULT 0,
  cost        numeric DEFAULT 0,
  mrp         numeric DEFAULT 0,
  disc        numeric DEFAULT 10,
  sale_price  numeric DEFAULT 0,
  photos      jsonb DEFAULT '[]'::jsonb,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: SALES
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sales (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inv               text UNIQUE,
  date              date,
  customer          jsonb,
  items             jsonb,
  sub               numeric,
  gst_pct           numeric,
  gst_amt           numeric,
  discount          numeric,
  total             numeric,
  paid              numeric,
  balance           numeric,
  mode              text,
  delivery_mode     text,
  shipping_status   text,
  shipping          jsonb,
  notes             text,
  created_by        text,
  created_at        timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: PURCHASES
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchases (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  date        date,
  seller      text,
  wa          text,
  place       text,
  items       jsonb,
  sub         numeric,
  gst_pct     numeric,
  gst_amt     numeric,
  total       numeric,
  payment     jsonb,
  created_at  timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: OVERHEADS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS overheads (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  date        date,
  cat         text,
  description text,
  unit_price  numeric,
  qty         numeric,
  total       numeric,
  paid_by     text,
  shalini     numeric,
  meenakshi   numeric,
  tags        jsonb DEFAULT '[]'::jsonb,
  note        text,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: USERS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username       text UNIQUE NOT NULL,
  password_hash  text,
  display_name   text,
  role           text,
  wa             text,
  active         boolean DEFAULT true,
  last_login     timestamptz,
  created_at     timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: SETTINGS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS settings (
  id          bigserial PRIMARY KEY,
  key         text UNIQUE NOT NULL,
  value       text,
  updated_at  timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: REVIEWS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reviews (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name  text,
  display_name   text,
  wa             text,
  rating         smallint,
  review_text    text,
  photo_url      text,
  invoice_ref    text,
  status         text DEFAULT 'pending',
  created_at     timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: REQUESTS (customer "notify me")
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS requests (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name  text,
  wa             text,
  item_name      text,
  item_id        text,
  notes          text,
  status         text DEFAULT 'new',
  created_at     timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: POPUPS (events)
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS popups (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title          text,
  dates          text,
  timings        text,
  location       text,
  writeup        text,
  status         text DEFAULT 'upcoming',
  photos         jsonb DEFAULT '[]'::jsonb,
  display_order  integer DEFAULT 0,
  created_at     timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: INSTAGRAM POSTS
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS instagram_posts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_url       text,
  image_url      text,
  caption        text,
  display_order  integer DEFAULT 0,
  active         boolean DEFAULT true,
  created_at     timestamptz DEFAULT now()
);

-- ───────────────────────────────────────────────────────────────
-- BASE: RLS (permissive — tighten in M11)
-- ───────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'inventory','sales','purchases','overheads','users',
    'settings','reviews','requests','popups','instagram_posts'
  ]) LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_anon" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_anon" ON %I FOR ALL TO anon USING (true) WITH CHECK (true);', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_auth" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_auth" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true);', t);
  END LOOP;
END$$;


-- ═══════════════════════════════════════════════════════════════
-- M1: VENDORS (suppliers)
-- ═══════════════════════════════════════════════════════════════
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
-- M1: INVENTORY SKUs (product types)
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inventory_skus (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku_code         text UNIQUE NOT NULL,
  pattern          text,
  material         text,
  variant          text,
  name             text NOT NULL,
  display_material text,
  display_variant  text,
  tags             jsonb NOT NULL DEFAULT '[]'::jsonb,
  cost             numeric NOT NULL DEFAULT 0,
  mrp              numeric NOT NULL DEFAULT 0,
  disc             numeric NOT NULL DEFAULT 10,
  sale_price       numeric NOT NULL DEFAULT 0,
  sale_price_aud   numeric NOT NULL DEFAULT 0,
  hero_photo       text,
  description      text,
  legacy_item_id   text,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_skus_code ON inventory_skus(sku_code);
CREATE INDEX IF NOT EXISTS idx_skus_pattern ON inventory_skus(pattern);

-- Per-vendor-per-SKU batch counter
CREATE TABLE IF NOT EXISTS sku_vendor_batches (
  sku_id        uuid NOT NULL REFERENCES inventory_skus(id) ON DELETE CASCADE,
  vendor_id     text NOT NULL REFERENCES vendors(vendor_id) ON UPDATE CASCADE,
  batch_counter integer NOT NULL DEFAULT 0,
  updated_at    timestamptz DEFAULT now(),
  PRIMARY KEY (sku_id, vendor_id)
);

-- ───────────────────────────────────────────────────────────────
-- M1: Extend PURCHASES with new columns
-- ───────────────────────────────────────────────────────────────
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS supplier_inv text;
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS vendor_uuid  uuid REFERENCES vendors(id);
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS vendor_code  text;
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS txn_id       uuid UNIQUE DEFAULT gen_random_uuid();
ALTER TABLE purchases ADD COLUMN IF NOT EXISTS is_migration boolean DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_purch_vendor ON purchases(vendor_uuid);
CREATE INDEX IF NOT EXISTS idx_purch_supplier_inv ON purchases(supplier_inv);

-- ───────────────────────────────────────────────────────────────
-- M1: INVENTORY UNITS (individual physical pieces)
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inventory_units (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_code         text UNIQUE NOT NULL,
  sku_id            uuid NOT NULL REFERENCES inventory_skus(id) ON DELETE RESTRICT,
  purchase_id       uuid REFERENCES purchases(id) ON DELETE SET NULL,
  vendor_code       text,
  batch             text NOT NULL,
  unit_num          smallint NOT NULL,
  photo_url         text,
  status            text NOT NULL DEFAULT 'available',
  sold_in_sale_id   uuid,
  reserved_until    timestamptz,
  txn_id            uuid UNIQUE NOT NULL DEFAULT gen_random_uuid(),
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now(),
  CHECK (status IN ('available','sold','reserved','damaged'))
);
CREATE INDEX IF NOT EXISTS idx_units_sku ON inventory_units(sku_id);
CREATE INDEX IF NOT EXISTS idx_units_vendor ON inventory_units(vendor_code);
CREATE INDEX IF NOT EXISTS idx_units_status ON inventory_units(status);
CREATE INDEX IF NOT EXISTS idx_units_batch ON inventory_units(sku_id,vendor_code,batch);

-- ───────────────────────────────────────────────────────────────
-- M1: VENDOR ISSUES
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
-- M1: VENDOR ID EDIT REQUESTS
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
-- M1: VENDOR AUDIT LOG
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
-- M1: Add txn_id to sales + overheads
-- ───────────────────────────────────────────────────────────────
ALTER TABLE sales      ADD COLUMN IF NOT EXISTS txn_id uuid UNIQUE DEFAULT gen_random_uuid();
ALTER TABLE overheads  ADD COLUMN IF NOT EXISTS txn_id uuid UNIQUE DEFAULT gen_random_uuid();
UPDATE sales     SET txn_id = gen_random_uuid() WHERE txn_id IS NULL;
UPDATE overheads SET txn_id = gen_random_uuid() WHERE txn_id IS NULL;

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — next_vendor_id (atomic 3-digit sequence)
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

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — create_batch_units (atomic batch bump + unit rows)
-- ───────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — claim_unit (atomic sell, no double-sell)
-- ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION claim_unit(p_unit_id uuid, p_sale_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE rows_affected integer;
BEGIN
  UPDATE inventory_units
     SET status = 'sold', sold_in_sale_id = p_sale_id,
         reserved_until = NULL, updated_at = now()
   WHERE id = p_unit_id AND status IN ('available','reserved');
  GET DIAGNOSTICS rows_affected = ROW_COUNT;
  RETURN rows_affected > 0;
END;$$;

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — reserve_unit (15-min cart hold)
-- ───────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — release_expired_reservations
-- ───────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────
-- M1: RPC — change_vendor_id (cascades to unit codes)
-- ───────────────────────────────────────────────────────────────
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
-- M1: RLS for new tables
-- ───────────────────────────────────────────────────────────────
ALTER TABLE vendors              ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_skus       ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_units      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sku_vendor_batches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_issues        ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_edit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_audit_log     ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'vendors','inventory_skus','inventory_units','sku_vendor_batches',
    'vendor_issues','vendor_edit_requests','vendor_audit_log'
  ]) LOOP
    EXECUTE format('DROP POLICY IF EXISTS "all_anon" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_anon" ON %I FOR ALL TO anon USING (true) WITH CHECK (true);', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_auth" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_auth" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true);', t);
  END LOOP;
END$$;

-- ───────────────────────────────────────────────────────────────
-- M1: SETTINGS seeds
-- ───────────────────────────────────────────────────────────────
INSERT INTO settings(key, value)
SELECT 'aud_multiplier', '1.8'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'aud_multiplier');

INSERT INTO settings(key, value)
SELECT 'wa_num_in', '918709525218'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'wa_num_in');

INSERT INTO settings(key, value)
SELECT 'wa_num_au', ''
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'wa_num_au');

INSERT INTO settings(key, value)
SELECT 'anthropic_key', ''
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'anthropic_key');

INSERT INTO settings(key, value)
SELECT 'sku_shorthands', '{
  "patterns": {
    "PAITH": "Paithani", "AJRAK": "Ajrak", "MADH": "Madhubani",
    "HPNT": "Handpainted", "GHIC": "Ghicha", "IKKAT": "Ikkat",
    "KALAM": "Kalamkari", "GHARC": "Gharchola", "KOTA": "Kota Doria",
    "PATOL": "Patola", "DOLA": "Dola", "POCHA": "Pochampally",
    "MODAL": "Modal", "MULCT": "Mul Cotton", "TUSSA": "Tussar",
    "BANAR": "Banarasi", "BANDH": "Bandhej", "SEMIA": "Semi Ajrak"
  },
  "materials": {
    "COT": "Cotton", "SLK": "Silk", "TUS": "Tussar", "MOD": "Modal",
    "MSK": "Modal Silk", "CSK": "Cotton Silk", "TSK": "Tussar Silk", "KTD": "Kota Doria"
  },
  "variants": {
    "PL": "Plain", "HP": "Handpainted", "GH": "Ghicha", "MD": "Madhubani",
    "BP": "Block Print", "SP": "Screen Print", "ST": "Suit", "DP": "Dupin",
    "SA": "Semi Ajrak", "BN": "Bandhej"
  }
}'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'sku_shorthands');


-- ═══════════════════════════════════════════════════════════════
-- AUTH: Extend users table
-- ═══════════════════════════════════════════════════════════════
ALTER TABLE users ADD COLUMN IF NOT EXISTS email                text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password boolean DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_password_change timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_updated_via text;

-- ───────────────────────────────────────────────────────────────
-- AUTH: auth_log
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS auth_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username    text,
  success     boolean NOT NULL,
  reason      text,
  ip_guess    text,
  user_agent  text,
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_auth_log_username ON auth_log(username);
CREATE INDEX IF NOT EXISTS idx_auth_log_created  ON auth_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_log_fail     ON auth_log(username, success, created_at DESC);

-- ───────────────────────────────────────────────────────────────
-- AUTH: password_reset_requests
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS password_reset_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text NOT NULL,
  note          text,
  status        text NOT NULL DEFAULT 'pending',
  fulfilled_by  text,
  fulfilled_at  timestamptz,
  generated_pw  text,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_prr_status ON password_reset_requests(status);

-- ───────────────────────────────────────────────────────────────
-- AUTH: recovery_codes
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS recovery_codes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES users(id) ON DELETE CASCADE,
  username    text NOT NULL,
  code_hash   text NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rc_username ON recovery_codes(username);
CREATE INDEX IF NOT EXISTS idx_rc_hash     ON recovery_codes(code_hash);

-- ───────────────────────────────────────────────────────────────
-- AUTH: email_reset_tokens
-- ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS email_reset_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text NOT NULL,
  token_hash    text NOT NULL,
  expires_at    timestamptz NOT NULL,
  used_at       timestamptz,
  sent_to_email text,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ert_hash     ON email_reset_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_ert_username ON email_reset_tokens(username);

-- ───────────────────────────────────────────────────────────────
-- AUTH: Seed default users (won't overwrite if already exist)
-- ───────────────────────────────────────────────────────────────
INSERT INTO users(username, password_hash, display_name, role, wa, active)
SELECT 'shameen','admin@123','Deedee','super_admin','918709525218',true
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='shameen');

INSERT INTO users(username, password_hash, display_name, role, wa, active)
SELECT 'shalini','shalini@123','Shalini','owner','',true
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='shalini');

INSERT INTO users(username, password_hash, display_name, role, wa, active)
SELECT 'meenakshi','meenakshi@123','Meenakshi','owner','918709525218',true
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='meenakshi');

INSERT INTO users(username, password_hash, display_name, role, wa, active)
SELECT 'sales1','sales@123','Sales','sales','',true
WHERE NOT EXISTS (SELECT 1 FROM users WHERE username='sales1');

INSERT INTO settings(key, value)
SELECT 'rachnakar_recovery_email', 'meensha.fabrics@gmail.com'
WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='rachnakar_recovery_email');

-- ───────────────────────────────────────────────────────────────
-- AUTH: RLS
-- ───────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'auth_log','password_reset_requests','recovery_codes','email_reset_tokens'
  ]) LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_anon" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_anon" ON %I FOR ALL TO anon USING (true) WITH CHECK (true);', t);
    EXECUTE format('DROP POLICY IF EXISTS "all_auth" ON %I;', t);
    EXECUTE format('CREATE POLICY "all_auth" ON %I FOR ALL TO authenticated USING (true) WITH CHECK (true);', t);
  END LOOP;
END$$;

-- AUTH: RPC — recent_failed_logins
CREATE OR REPLACE FUNCTION recent_failed_logins(p_username text, p_minutes integer DEFAULT 15)
RETURNS integer LANGUAGE sql STABLE AS $$
  SELECT count(*)::integer FROM auth_log
   WHERE username = p_username AND success = false
     AND created_at > now() - (p_minutes || ' minutes')::interval;
$$;


-- ═══════════════════════════════════════════════════════════════
-- VERIFY (run these manually after to confirm success):
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public' ORDER BY table_name;
--
--   SELECT next_vendor_id();          -- should return '001'
--   SELECT count(*) FROM users;       -- should return 4
--   SELECT count(*) FROM settings;    -- should return 6+
-- ═══════════════════════════════════════════════════════════════
