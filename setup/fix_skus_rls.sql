-- inventory_skus/inventory_units came from an earlier/different schema run
-- and their RLS policies may not match what our app expects (anon full access,
-- same as every other table in this app). Reset them explicitly.

ALTER TABLE inventory_skus  ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "all_anon" ON inventory_skus;
CREATE POLICY "all_anon" ON inventory_skus FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON inventory_skus;
CREATE POLICY "all_auth" ON inventory_skus FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "all_anon" ON inventory_units;
CREATE POLICY "all_anon" ON inventory_units FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON inventory_units;
CREATE POLICY "all_auth" ON inventory_units FOR ALL TO authenticated USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
