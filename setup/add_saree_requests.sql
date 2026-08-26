-- "Request a Saree" — extends the existing (previously dead-scaffolding)
-- `requests` table into a real, tracked customer-request flow. See the plan
-- doc referenced in the commit for full context.
--
-- Trust model mirrors submit_review exactly: the customer's wa/name are
-- resolved server-side from their session token, never trusted from the
-- client — a customer can't submit a request "as" someone else.

ALTER TABLE requests ADD COLUMN IF NOT EXISTS region text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS instagram_handle text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS quantity int DEFAULT 1;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS photo_url text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS contacted_by text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS contacted_at timestamptz;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS reply_message text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS dismissed_by text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS dismissed_at timestamptz;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS dismissed_notes text;

-- status real values in practice: 'new' (default, unchanged) -> 'contacted'
-- (staff replied to the customer) -> 'done' (item received/delivered) or
-- 'not_done' (couldn't be sourced). Plain text column, no CHECK constraint
-- added, to match this project's existing convention on this table.

CREATE OR REPLACE FUNCTION submit_saree_request(
  p_token text,
  p_item_id text,
  p_item_name text,
  p_quantity int,
  p_notes text,
  p_photo_url text,
  p_instagram_handle text,
  p_region text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wa text;
  v_name text;
  v_id uuid;
BEGIN
  SELECT cs.wa, c.name INTO v_wa, v_name
    FROM customer_sessions cs JOIN customers c ON c.id = cs.customer_id
    WHERE cs.token = p_token AND cs.expires_at > now();
  IF v_wa IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_logged_in');
  END IF;

  INSERT INTO requests (customer_name, wa, item_name, item_id, notes, quantity, photo_url, instagram_handle, region, status)
    VALUES (v_name, v_wa, p_item_name, p_item_id, p_notes, coalesce(p_quantity, 1), p_photo_url, p_instagram_handle, p_region, 'new')
    RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_saree_request(text, text, text, int, text, text, text, text) TO anon, authenticated;

-- Storage bucket for the optional request screenshot. Bucket itself was
-- already created via the Storage API (public, 5MB cap, image/* only) —
-- this just adds the matching anon-write policy, same pattern as
-- item-photos (setup/create_storage_bucket.sql).
INSERT INTO storage.buckets (id, name, public)
VALUES ('request-photos', 'request-photos', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "request_photos_anon_all" ON storage.objects;
CREATE POLICY "request_photos_anon_all" ON storage.objects
  FOR ALL TO anon
  USING (bucket_id = 'request-photos')
  WITH CHECK (bucket_id = 'request-photos');

DROP POLICY IF EXISTS "request_photos_public_read" ON storage.objects;
CREATE POLICY "request_photos_public_read" ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'request-photos');

NOTIFY pgrst, 'reload schema';
