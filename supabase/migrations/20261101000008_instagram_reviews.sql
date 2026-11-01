-- Instagram collab/tagged posts pulled in as reviews. They land in the same
-- `reviews` table as pending rows, so the existing Reviews tab (Approve /
-- Reject) moderates them and the storefront's approved-only query shows them.
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'verified';
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS ig_media_id text;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS ig_permalink text;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS ig_username text;
CREATE UNIQUE INDEX IF NOT EXISTS reviews_ig_media_id_key ON reviews (ig_media_id) WHERE ig_media_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';
