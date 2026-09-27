-- Atomic single-photo append for inventory_skus.photos (jsonb array) —
-- fixes a lost-update race in the new "Add photo to item" bot flow
-- (telegram-bot/index.ts handleAddPhotoUpload, telegram-bot-au's Au
-- equivalent): the old code read the row's photos once at session start,
-- appended in application memory, then overwrote the whole column on each
-- upload — two photos sent back-to-back could each read the same stale
-- array and the second write would silently drop the first photo. This
-- RPC does the append as one UPDATE statement, so Postgres's normal
-- row-level locking serializes concurrent calls correctly instead of the
-- application racing itself.
CREATE OR REPLACE FUNCTION append_sku_photo(p_sku_id uuid, p_url text)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE inventory_skus
  SET photos = COALESCE(photos, '[]'::jsonb) || to_jsonb(p_url::text),
      updated_at = now()
  WHERE id = p_sku_id
  RETURNING photos;
$$;
GRANT EXECUTE ON FUNCTION append_sku_photo(uuid, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
