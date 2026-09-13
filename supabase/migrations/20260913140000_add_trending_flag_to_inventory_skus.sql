-- Adds the staff-controlled "Trending" flag for the storefront product
-- badge (SEO + Instagram growth initiative, see TODO.md). Authoritative —
-- set only by staff in admin.html's Inventory tab. The "NEW" badge needs
-- no schema change: it's a 14-day window on inventory_skus.created_at,
-- which already exists.

ALTER TABLE inventory_skus
  ADD COLUMN IF NOT EXISTS trending boolean NOT NULL DEFAULT false;

NOTIFY pgrst, 'reload schema';
