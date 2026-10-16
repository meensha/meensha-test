-- The original migration enabled RLS on this table but never added a policy
-- (every other table in this codebase pairs the two) -- with RLS on and no
-- policy, Postgres denies all anon/authenticated REST access by default, so
-- the Potential Customers list screen's direct reads/writes would silently
-- return nothing against production. Same permissive policy shape already
-- used elsewhere in this codebase (e.g. setup/schema_combined.sql:181-194).
CREATE POLICY "all_anon" ON potential_customers FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "all_auth" ON potential_customers FOR ALL TO authenticated USING (true) WITH CHECK (true);
