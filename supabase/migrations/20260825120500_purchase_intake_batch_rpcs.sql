-- Batch-level RPCs on top of the widened stock_intake_drafts (see previous
-- migration). Purely additive — existing submit_stock_intake_draft /
-- admin_approve_stock_intake_draft / admin_reject_stock_intake_draft (used
-- by the live AU bot) are untouched.
--
-- submit_purchase_intake_batch: writes one stock_intake_drafts row per item,
--   all sharing one batch_id. Nothing else is written — this is the staged
--   "not live yet" step.
-- admin_approve_purchase_batch: the only place anything becomes real
--   inventory. Creates one purchases header, then per item either
--   create_batch_units (into inventory_units, sellable) or a
--   inventory_returns_pending row (defective — never touches
--   inventory_units), then a vendor_audit_log entry as the audit trail.
-- admin_reject_purchase_batch: marks the whole batch rejected, nothing
--   written to inventory/purchases.

CREATE OR REPLACE FUNCTION submit_purchase_intake_batch(
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

CREATE OR REPLACE FUNCTION admin_approve_purchase_batch(
  p_batch_id uuid,
  p_reviewed_by text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_purchase_id  uuid;
  v_vendor_uuid  uuid;
  v_vendor_code  text;
  v_payment      jsonb;
  v_items        jsonb := '[]'::jsonb;
  v_total        numeric := 0;
  v_row          record;
  v_sku_id       uuid;
  v_units_affected integer := 0;
  v_pending_count  integer;
BEGIN
  SELECT vendor_uuid, payment INTO v_vendor_uuid, v_payment
  FROM stock_intake_drafts WHERE batch_id = p_batch_id LIMIT 1;

  IF v_vendor_uuid IS NULL THEN
    RAISE EXCEPTION 'Batch % has no vendor or does not exist', p_batch_id;
  END IF;

  SELECT count(*) INTO v_pending_count
  FROM stock_intake_drafts WHERE batch_id = p_batch_id AND status = 'pending';
  IF v_pending_count = 0 THEN
    RAISE EXCEPTION 'Batch % has no pending items left to approve', p_batch_id;
  END IF;

  SELECT vendor_id INTO v_vendor_code FROM vendors WHERE id = v_vendor_uuid;

  INSERT INTO purchases (vendor_uuid, vendor_code, date, payment, items, total, sub)
  VALUES (v_vendor_uuid, v_vendor_code, CURRENT_DATE, v_payment, '[]'::jsonb, 0, 0)
  RETURNING id INTO v_purchase_id;

  FOR v_row IN
    SELECT * FROM stock_intake_drafts
    WHERE batch_id = p_batch_id AND status = 'pending'
    ORDER BY created_at
  LOOP
    IF v_row.is_defective THEN
      INSERT INTO inventory_returns_pending (sku_id, purchase_id, vendor_uuid, qty, reason, photo_url, flagged_by)
      VALUES (
        v_row.sku_id, v_purchase_id, v_vendor_uuid,
        COALESCE(v_row.defect_qty, v_row.qty), v_row.defect_reason,
        v_row.photo_urls->>0, p_reviewed_by
      );
    ELSE
      v_sku_id := v_row.sku_id;
      IF v_sku_id IS NULL THEN
        INSERT INTO inventory_skus (name, material, variant, sale_price, cost)
        VALUES (v_row.proposed_name, v_row.proposed_material, v_row.proposed_variant, v_row.proposed_sale_price, v_row.purchase_price)
        RETURNING id INTO v_sku_id;
      END IF;

      PERFORM create_batch_units(
        p_sku_id := v_sku_id,
        p_vendor_code := v_vendor_code,
        p_purchase_id := v_purchase_id,
        p_qty := v_row.qty,
        p_photo_urls := ARRAY(SELECT jsonb_array_elements_text(v_row.photo_urls))
      );
      v_units_affected := v_units_affected + v_row.qty;
    END IF;

    v_items := v_items || jsonb_build_object(
      'name', v_row.proposed_name,
      'material', v_row.proposed_material,
      'variant', v_row.proposed_variant,
      'qty', v_row.qty,
      'cost', v_row.purchase_price,
      'defective', v_row.is_defective
    );
    v_total := v_total + COALESCE(v_row.purchase_price, 0) * v_row.qty;

    UPDATE stock_intake_drafts
    SET status = 'approved', reviewed_by = p_reviewed_by, reviewed_at = now()
    WHERE id = v_row.id;
  END LOOP;

  UPDATE purchases SET items = v_items, total = v_total, sub = v_total WHERE id = v_purchase_id;

  INSERT INTO vendor_audit_log (vendor_uuid, action, new_value, performed_by, units_affected)
  VALUES (v_vendor_uuid, 'purchase_approved', v_purchase_id::text, p_reviewed_by, v_units_affected);

  RETURN v_purchase_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin_reject_purchase_batch(
  p_batch_id uuid,
  p_reason text,
  p_reviewed_by text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE stock_intake_drafts
  SET status = 'rejected', rejection_reason = p_reason, reviewed_by = p_reviewed_by, reviewed_at = now()
  WHERE batch_id = p_batch_id AND status = 'pending';
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_purchase_intake_batch(uuid, jsonb, jsonb, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_approve_purchase_batch(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_reject_purchase_batch(uuid, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
