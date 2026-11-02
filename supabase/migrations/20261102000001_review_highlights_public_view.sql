-- NOT APPLIED. Idempotent. Apply this one FIRST (before any follow-up RLS tightening).
-- 1) reviews.comment_highlights: owner-approved comment snippets, JSON array of at most 6 items
--    ({text,author,theme}); written from admin.html, shown on review-share.html.
-- 2) public_reviews: a view with only safe columns (no wa, customer_name, invoice_ref, sale_id,
--    ig_username, ig_media_id) for approved rows. Runs with the view owner's rights (default),
--    so it keeps working if anon's SELECT on the base table is later removed.
--
-- The pages (index.html, review-share.html) already request an explicit safe column list and try
-- this view first, falling back to the base table, so nothing breaks before this is applied.
-- Follow-ups (not here): REVOKE SELECT ON reviews FROM anon + drop the base-table public policy
-- and remove the table fallback from the two pages; owner-only write policy on reviews.
BEGIN;

ALTER TABLE reviews ADD COLUMN IF NOT EXISTS comment_highlights jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reviews_comment_highlights_chk') THEN
    ALTER TABLE reviews ADD CONSTRAINT reviews_comment_highlights_chk
      CHECK (jsonb_typeof(comment_highlights) = 'array' AND jsonb_array_length(comment_highlights) <= 6);
  END IF;
END $$;

CREATE OR REPLACE VIEW public_reviews WITH (security_barrier = true) AS
  SELECT id, rating, review_text, display_name, source, ig_permalink, photo_url,
         created_at, status, comment_highlights
  FROM reviews
  WHERE status = 'approved';

-- New relations get default INSERT/UPDATE/DELETE grants for anon; this view is auto-updatable,
-- so strip everything first, then allow read only.
REVOKE ALL ON public_reviews FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public_reviews TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
