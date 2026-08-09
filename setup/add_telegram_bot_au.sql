-- Australia staff bot (@meenshaozbot) — separate Edge Function, separate bot
-- token, separate auth/session tables from the existing India/Shalini bot.
-- Deliberately NOT sharing telegram_allowed_users/telegram_sessions with the
-- existing bot: chat_id is the person's own Telegram ID, not bot-scoped, so
-- if anyone ever messages both bots with the same Telegram account, sharing
-- those tables would let an allowlist entry or in-flight conversation state
-- leak across bots. Mirrors the same table shapes/RPC patterns already
-- proven for the existing bot, just with an _au suffix.

CREATE TABLE IF NOT EXISTS telegram_allowed_users_au (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id    text UNIQUE NOT NULL,
  label      text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_allowed_users_au ENABLE ROW LEVEL SECURITY;
-- Intentionally no anon/authenticated policies — RPC-only, same reasoning as the India table.

CREATE OR REPLACE FUNCTION admin_list_telegram_users_au()
RETURNS SETOF telegram_allowed_users_au
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM telegram_allowed_users_au ORDER BY created_at DESC;
$$;

CREATE OR REPLACE FUNCTION admin_add_telegram_user_au(p_chat_id text, p_label text)
RETURNS telegram_allowed_users_au
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r telegram_allowed_users_au;
BEGIN
  INSERT INTO telegram_allowed_users_au (chat_id, label)
  VALUES (trim(p_chat_id), p_label)
  RETURNING * INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION admin_set_telegram_user_au_active(p_id uuid, p_active boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE telegram_allowed_users_au SET active = p_active WHERE id = p_id;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_telegram_user_au(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM telegram_allowed_users_au WHERE id = p_id;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_telegram_users_au() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_add_telegram_user_au(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_set_telegram_user_au_active(uuid, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_telegram_user_au(uuid) TO anon, authenticated;

-- Session/conversation state, same shape as telegram_sessions, separate table.
CREATE TABLE IF NOT EXISTS telegram_sessions_au (
  chat_id    bigint PRIMARY KEY,
  state      text NOT NULL DEFAULT 'idle',
  data       jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_sessions_au ENABLE ROW LEVEL SECURITY;
-- No policies — service_role only, same as telegram_sessions.

-- Stock Intake draft-approval staging table (new concept — does not exist
-- for the India bot, which writes directly to inventory). A draft here is
-- NOT live inventory; it only becomes real inventory_skus/inventory_units
-- rows once approved on the web dashboard (admin.html), via a new RPC.
CREATE TABLE IF NOT EXISTS stock_intake_drafts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  region              text NOT NULL DEFAULT 'australia' CHECK (region IN ('india','australia')),
  -- If matched to an existing SKU during intake, sku_id is set and the
  -- name/material/variant fields below are just a cached copy for display;
  -- if genuinely new, sku_id is NULL and those fields are the real proposal.
  sku_id              uuid REFERENCES inventory_skus(id),
  proposed_name       text,
  proposed_material   text,
  proposed_variant    text,
  purchase_price      numeric,
  proposed_sale_price numeric,
  notes               text,
  photo_urls          jsonb NOT NULL DEFAULT '[]'::jsonb,
  qty                 integer NOT NULL DEFAULT 1,
  status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  submitted_by        text,           -- telegram label/chat_id of who submitted
  reviewed_by         text,
  reviewed_at         timestamptz,
  rejection_reason    text,
  created_at          timestamptz DEFAULT now()
);
ALTER TABLE stock_intake_drafts ENABLE ROW LEVEL SECURITY;
-- RPC-only, same reasoning as everything else here — a draft becoming real
-- inventory is an inventory-creating action, shouldn't be anon-writable directly.

CREATE OR REPLACE FUNCTION submit_stock_intake_draft(
  p_region text, p_sku_id uuid, p_proposed_name text, p_proposed_material text,
  p_proposed_variant text, p_purchase_price numeric, p_proposed_sale_price numeric,
  p_notes text, p_photo_urls jsonb, p_qty integer, p_submitted_by text
)
RETURNS stock_intake_drafts
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r stock_intake_drafts;
BEGIN
  INSERT INTO stock_intake_drafts (
    region, sku_id, proposed_name, proposed_material, proposed_variant,
    purchase_price, proposed_sale_price, notes, photo_urls, qty, submitted_by
  ) VALUES (
    p_region, p_sku_id, p_proposed_name, p_proposed_material, p_proposed_variant,
    p_purchase_price, p_proposed_sale_price, p_notes, p_photo_urls, p_qty, p_submitted_by
  ) RETURNING * INTO r;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION admin_list_stock_intake_drafts(p_status text DEFAULT 'pending')
RETURNS SETOF stock_intake_drafts
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM stock_intake_drafts WHERE status = p_status ORDER BY created_at ASC;
$$;

-- Approve a draft: creates/reuses the SKU, creates real inventory_units via
-- the existing create_batch_units RPC, marks the draft approved. Does NOT
-- create a purchases row automatically — vendor/payment detail for a
-- popup-event acquisition is expected to be entered separately on the web
-- dashboard by whoever approves, same as any other purchase entry; this
-- keeps the draft's own required fields minimal for fast phone entry.
CREATE OR REPLACE FUNCTION admin_approve_stock_intake_draft(
  p_draft_id uuid, p_reviewed_by text, p_vendor_code text, p_purchase_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d stock_intake_drafts; v_sku_id uuid; v_result jsonb;
BEGIN
  SELECT * INTO d FROM stock_intake_drafts WHERE id = p_draft_id AND status = 'pending';
  IF d IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Draft not found or already reviewed.');
  END IF;

  v_sku_id := d.sku_id;
  IF v_sku_id IS NULL THEN
    INSERT INTO inventory_skus (
      sku_code, name, material, variant, cost, sale_price, sale_price_aud,
      photos, india_available, au_available
    ) VALUES (
      'AU-' || to_char(now(), 'YYMMDDHH24MISS'),
      d.proposed_name, d.proposed_material, d.proposed_variant,
      COALESCE(d.purchase_price, 0),
      CASE WHEN d.region = 'india' THEN COALESCE(d.proposed_sale_price, 0) ELSE 0 END,
      CASE WHEN d.region = 'australia' THEN COALESCE(d.proposed_sale_price, 0) ELSE 0 END,
      d.photo_urls,
      d.region = 'india', d.region = 'australia'
    ) RETURNING id INTO v_sku_id;
  END IF;

  SELECT jsonb_agg(row_to_json(u)) INTO v_result
  FROM create_batch_units(v_sku_id, p_vendor_code, p_purchase_id, d.qty,
    ARRAY(SELECT jsonb_array_elements_text(d.photo_urls))) u;

  UPDATE stock_intake_drafts
     SET status = 'approved', reviewed_by = p_reviewed_by, reviewed_at = now()
   WHERE id = p_draft_id;

  RETURN jsonb_build_object('ok', true, 'sku_id', v_sku_id, 'units', v_result);
END;
$$;

CREATE OR REPLACE FUNCTION admin_reject_stock_intake_draft(p_draft_id uuid, p_reviewed_by text, p_reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE stock_intake_drafts
     SET status = 'rejected', reviewed_by = p_reviewed_by, reviewed_at = now(), rejection_reason = p_reason
   WHERE id = p_draft_id AND status = 'pending';
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION submit_stock_intake_draft(text, uuid, text, text, text, numeric, numeric, text, jsonb, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_list_stock_intake_drafts(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_approve_stock_intake_draft(uuid, text, text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_reject_stock_intake_draft(uuid, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
