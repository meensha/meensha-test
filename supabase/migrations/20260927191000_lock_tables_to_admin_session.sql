-- Lock business tables to admin sessions.
--
-- Until now every table below had an "allow everything" policy for anon (and
-- often authenticated), so the public anon key in the storefront could read
-- and rewrite sales, purchases, costs, vendors, users, etc. Now anon only gets
-- in with a valid x-admin-session header (has_admin_session()); service-role
-- callers (edge functions, bots) and pg_cron bypass RLS as before.
--
-- Nothing uses Supabase Auth (auth.users is empty), so the "authenticated"
-- allow-all policies are dropped rather than rewritten — anyone could sign up
-- for an authenticated token.
--
-- Still public after this: the "Public read ..." SELECT policies on
-- instagram_posts, popups, reviews (approved) and settings (safe keys),
-- page_views inserts, and the public_skus / public_units views.
-- Depends on 20260927190000_public_views_and_rpcs.sql and the page updates
-- that shipped with it.

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'auth_log', 'bot_notes', 'instagram_posts', 'inventory', 'inventory_returns_pending',
    'inventory_skus', 'inventory_units', 'notifications', 'overheads', 'password_reset_requests',
    'popups', 'purchases', 'push_subscriptions', 'requests', 'reviews', 'sales', 'settings',
    'sku_vendor_batches', 'users', 'vendor_audit_log', 'vendor_edit_requests', 'vendor_issues', 'vendors'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS "open" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS all_anon ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS all_auth ON public.%I', t);
    EXECUTE format('CREATE POLICY admin_session ON public.%I FOR ALL TO anon '
                   'USING ((SELECT has_admin_session())) WITH CHECK ((SELECT has_admin_session()))', t);
  END LOOP;
END $$;

-- Storefront reads these through public_skus / public_units now.
DROP POLICY "Public read SKUs" ON public.inventory_skus;
DROP POLICY "Public read units" ON public.inventory_units;
