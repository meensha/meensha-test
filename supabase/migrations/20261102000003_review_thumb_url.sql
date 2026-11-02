-- NOT APPLIED. Idempotent. Apply AFTER 20261102000002.
-- reviews.thumb_url: screengrab image for Instagram-link and story-video reviews (shown in the
-- homepage grid and as the poster in the popup / share page). Must be one of our review-media images.
-- public_reviews is recreated with thumb_url appended (existing columns keep their order; consent
-- columns stay out). Pages fall back to the old column list until this is applied.
BEGIN;

ALTER TABLE reviews ADD COLUMN IF NOT EXISTS thumb_url text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reviews_thumb_url_chk') THEN
    ALTER TABLE reviews ADD CONSTRAINT reviews_thumb_url_chk CHECK (
      thumb_url IS NULL OR thumb_url ~ '^https://eglanmhhcccsuhbxywua\.supabase\.co/storage/v1/object/public/review-media/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$');
  END IF;
END $$;

-- Highlights are shown without attribution: the view strips any stored 'author' key.
-- One-time scrub so the base table stops carrying commenter handles too (idempotent: only touches rows with a non-empty author).
UPDATE reviews SET comment_highlights = (
  SELECT jsonb_agg(CASE WHEN h ? 'author' THEN jsonb_set(h, '{author}', '""'::jsonb) ELSE h END)
  FROM jsonb_array_elements(comment_highlights) h)
WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(comment_highlights) h WHERE coalesce(h->>'author','') <> '');

CREATE OR REPLACE VIEW public_reviews WITH (security_barrier = true) AS
  SELECT id, rating, review_text, display_name, source, ig_permalink, photo_url,
         created_at, status,
         COALESCE((SELECT jsonb_agg(h - 'author') FROM jsonb_array_elements(comment_highlights) h), '[]'::jsonb) AS comment_highlights,
         thumb_url
  FROM reviews
  WHERE status = 'approved';

REVOKE ALL ON public_reviews FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public_reviews TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
