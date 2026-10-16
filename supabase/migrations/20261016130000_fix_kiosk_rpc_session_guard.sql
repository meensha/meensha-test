-- Three weeks ago, 20260927180000_admin_session_guard.sql revoked EXECUTE on
-- submit_purchase_intake_batch/append_sku_photo from anon/authenticated and
-- granted service_role only, on the (correct, at the time) assumption that
-- only the Telegram bot's service-role edge function ever called them.
--
-- Tonight's kiosk.html PWA calls both directly from the browser (anon key +
-- x-admin-session header, same pattern as every other admin_* RPC) for its
-- Vendor Purchase, Stock Intake, and "Add photo to item" screens -- so they
-- now need to be callable by an authenticated staff session too.
--
-- The naive fix (just re-granting EXECUTE) would be a real regression: these
-- functions have no internal auth check at all -- their only protection was
-- the GRANT/REVOKE itself. Re-granting without adding a session check would
-- make them callable by anyone holding just the public anon key, no login
-- required. Instead: add require_admin_session() at the top of each (same
-- gate every other admin_* RPC already uses), then re-grant. That function
-- already returns NULL (not an error) for a service_role caller, so the
-- Telegram bot's existing calls are unaffected.

CREATE OR REPLACE FUNCTION public.submit_purchase_intake_batch(
  p_vendor_uuid uuid,
  p_items jsonb,
  p_payment jsonb,
  p_submitted_by text,
  p_region text DEFAULT 'india'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_batch_id uuid := gen_random_uuid();
  v_item jsonb;
BEGIN
  PERFORM require_admin_session();

  IF p_vendor_uuid IS NULL THEN
    RAISE EXCEPTION 'vendor_uuid is required';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO stock_intake_drafts (
      region, vendor_uuid, batch_id, payment, sku_id,
      proposed_name, proposed_material, proposed_variant, proposed_sale_price,
      purchase_price, qty, photo_urls, notes,
      is_defective, defect_qty, defect_reason,
      submitted_by, status
    ) VALUES (
      p_region, p_vendor_uuid, v_batch_id, p_payment,
      NULLIF(v_item->>'sku_id', '')::uuid,
      v_item->>'proposed_name', v_item->>'proposed_material', v_item->>'proposed_variant',
      NULLIF(v_item->>'proposed_sale_price', '')::numeric,
      NULLIF(v_item->>'purchase_price', '')::numeric,
      COALESCE((v_item->>'qty')::integer, 1),
      COALESCE(v_item->'photo_urls', '[]'::jsonb),
      v_item->>'notes',
      COALESCE((v_item->>'is_defective')::boolean, false),
      NULLIF(v_item->>'defect_qty', '')::integer,
      v_item->>'defect_reason',
      p_submitted_by, 'pending'
    );
  END LOOP;

  RETURN v_batch_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.append_sku_photo(p_sku_id uuid, p_url text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_photos jsonb;
BEGIN
  PERFORM require_admin_session();
  UPDATE inventory_skus
  SET photos = COALESCE(photos, '[]'::jsonb) || to_jsonb(p_url::text),
      updated_at = now()
  WHERE id = p_sku_id
  RETURNING photos INTO v_photos;
  RETURN v_photos;
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_purchase_intake_batch(uuid, jsonb, jsonb, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.append_sku_photo(uuid, text) TO anon, authenticated;
