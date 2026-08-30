-- Storefront visitor counter — internal tracking only, reported in the
-- daily MeenshaMonitor digest, no public on-site display. Deliberately
-- minimal: a page-load log, not a full analytics/events system (the
-- broader `events` table sketched in MEENSHA_MONITORING.md was scoped
-- down to just this for now).

CREATE TABLE IF NOT EXISTS page_views (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  page       text NOT NULL, -- 'home' | 'about'
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_page_views_created_at ON page_views(created_at DESC);

ALTER TABLE page_views ENABLE ROW LEVEL SECURITY;
-- Anon can log a view (write-only) but never read the raw log back — same
-- trust level as every other anon-write table in this app (reviews,
-- requests before login-gating, etc.). Aggregation happens server-side via
-- the daily digest (service_role, bypasses RLS), not by querying this
-- table directly from the browser.
DROP POLICY IF EXISTS "page_views_anon_insert" ON page_views;
CREATE POLICY "page_views_anon_insert" ON page_views
  FOR INSERT TO anon WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
