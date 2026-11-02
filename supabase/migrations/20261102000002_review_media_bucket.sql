-- NOT APPLIED. Idempotent. Apply AFTER 20261102000001.
-- Locked bucket for customer story screenshots / short videos.
-- Public bucket = public read by URL. Deliberately NO storage.objects policies for it:
-- writes happen only through the upload-review-media edge function (service role).
-- (Checked read-only: every existing storage.objects policy is scoped by bucket_id to
-- item-photos / qr-codes / request-photos, so none applies to 'review-media'.)
BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('review-media', 'review-media', true, 15728640,
        ARRAY['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime'])
ON CONFLICT (id) DO UPDATE SET public = true,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Consent record for story uploads (not exposed in the public_reviews view).
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS consent_at timestamptz;
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS consent_by text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reviews_story_consent_chk') THEN
    ALTER TABLE reviews ADD CONSTRAINT reviews_story_consent_chk
      CHECK (source <> 'story_upload' OR consent_at IS NOT NULL);
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
