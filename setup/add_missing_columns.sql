-- inventory_skus was created by an earlier/different schema run and is
-- missing several columns the app (and M1 migration) expects. Add them.
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS pattern          text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS variant          text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS display_material text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS display_variant  text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS hero_photo       text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS description      text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS legacy_item_id   text;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS sale_price_aud   numeric NOT NULL DEFAULT 0;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS updated_at       timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_skus_pattern ON inventory_skus(pattern);

-- Verify inventory_units has everything create_batch_units() needs too
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS unit_code   text;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS sku_id      uuid REFERENCES inventory_skus(id);
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS purchase_id uuid;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS vendor_code text;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS batch       text;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS unit_num    integer;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS photo_url   text;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS status      text DEFAULT 'available';
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS sold_in_sale_id uuid;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS reserved_until  timestamptz;
ALTER TABLE inventory_units ADD COLUMN IF NOT EXISTS updated_at  timestamptz DEFAULT now();

NOTIFY pgrst, 'reload schema';

-- Verify:
-- SELECT column_name FROM information_schema.columns
-- WHERE table_name='inventory_skus' ORDER BY ordinal_position;
