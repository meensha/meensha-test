-- The item-photos storage bucket was never created — all photo uploads
-- (both legacy inventory and the new SKU system) have been silently
-- failing and falling back to storing raw base64 data in the database.

INSERT INTO storage.buckets (id, name, public)
VALUES ('item-photos', 'item-photos', true)
ON CONFLICT (id) DO NOTHING;

-- Allow anon (the app's only role) to upload/update/read photos
DROP POLICY IF EXISTS "item_photos_anon_all" ON storage.objects;
CREATE POLICY "item_photos_anon_all" ON storage.objects
  FOR ALL TO anon
  USING (bucket_id = 'item-photos')
  WITH CHECK (bucket_id = 'item-photos');

DROP POLICY IF EXISTS "item_photos_public_read" ON storage.objects;
CREATE POLICY "item_photos_public_read" ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'item-photos');

-- Verify:
-- SELECT id, name, public FROM storage.buckets WHERE id = 'item-photos';
