# Telegram Bot — Detailed Build Plan (Shalini, v1)

Follows the approved broad outline (see chat history). This is the build-ready spec: exact schema, exact file, exact state machine, exact deploy steps. Read this alongside `supabase/functions/razorpay-webhook/index.ts` — that function is the template this one follows.

## 0. Where this lives relative to test2/origin — important, easy to get wrong

This project has two separate deployment concepts that are easy to conflate:

- **The Supabase backend** (`eglanmhhcccsuhbxywua` — schema, RPCs, Edge Functions, secrets) is **one single project**, shared identically by both git sites. There is no "staging backend" vs "production backend." When the bot's Edge Function is deployed via `supabase functions deploy telegram-bot`, it is immediately live — the same instant, for real, regardless of which git branch/site currently reflects admin.html/index.html changes. Deploying the bot is not gated by, or connected to, any `git push`.
- **The two git sites** (`test2` = meensha-test2 staging, `origin` = meensha-test = real production, meensha.in) only affect the static `admin.html`/`index.html` files. This matters here because of one specific piece: the **"↩ Return to seller" button** (section 1) needs to be added to admin.html's web UI, not just the bot. That change follows the normal flow already used all session — commit, push to `test2`, verify in-browser, then push to `origin` only when you explicitly ask for it (origin is still the real live site, same caution as always).
- **Practical order for this feature**: deploy the Edge Function + run the SQL migration first (backend, safe, instantly live but inert until something calls it) → build and test the bot end-to-end against that backend → separately, make and push the small admin.html web-UI addition for returns through the normal test2 → origin flow. The bot going live doesn't require any git push at all; the admin.html return-button addition does, and follows the existing pushed-only-when-you-say-so rule.

---

## 1. Schema changes (new SQL file: `meensha-test/setup/add_telegram_bot.sql`)

```sql
-- Session/conversation state — the Edge Function is stateless per-invocation,
-- so where-the-user-is-in-a-flow has to live somewhere between messages.
-- Same lockdown pattern as `orders`/`user_credentials`: RLS on, zero policies,
-- only the service_role-authenticated Edge Function can touch it.
CREATE TABLE IF NOT EXISTS telegram_sessions (
  chat_id    bigint PRIMARY KEY,
  state      text NOT NULL DEFAULT 'idle',
  data       jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_sessions ENABLE ROW LEVEL SECURITY;
-- no policies — service_role only

-- Vendor returns (defective pieces sent back) — did not exist anywhere before.
ALTER TABLE inventory_units DROP CONSTRAINT IF EXISTS inventory_units_status_check;
ALTER TABLE inventory_units ADD CONSTRAINT inventory_units_status_check
  CHECK (status IN ('available','sold','reserved','damaged','returned_to_vendor'));

CREATE TABLE IF NOT EXISTS purchase_returns (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id  uuid REFERENCES purchases(id),
  unit_ids     uuid[] NOT NULL,
  qty          integer NOT NULL,
  amount       numeric NOT NULL DEFAULT 0,  -- reduces cost of goods in P&L
  reason       text,
  returned_at  timestamptz DEFAULT now(),
  created_by   text
);
ALTER TABLE purchase_returns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "all_anon" ON purchase_returns;
CREATE POLICY "all_anon" ON purchase_returns FOR ALL TO anon USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "all_auth" ON purchase_returns;
CREATE POLICY "all_auth" ON purchase_returns FOR ALL TO authenticated USING (true) WITH CHECK (true);
-- Permissive like the rest of the app's operational tables (not sensitive
-- like coupons/passwords) — both admin.html and the bot write to it.

NOTIFY pgrst, 'reload schema';
```

**admin.html changes required alongside this** (not bot-only, per the resolved decision that returns must exist on both surfaces):
- Add State ○ Purchase Purchase Breakdown / Inventory tab: a "↩ Return to seller" action per unit, writing to `purchase_returns` + setting that unit's status to `returned_to_vendor`.
- `renderPnL()`/`exportPnLXL()`: subtract `SUM(purchase_returns.amount)` from `stockCost` so P&L doesn't overstate cost of goods for units that were sent back.

---

## 2. Bootstrap: getting Shalini's chat_id into the allowlist

Resolved decision was "hardcoded allowlist," which means a one-time manual step:
1. Deploy the bot (steps below) with `telegram_authorized_chat_id` in `settings` left empty.
2. Shalini messages the bot once. The function receives her `chat_id`, sees the setting is empty, replies "Not authorized yet — ask Rachnakar to approve chat_id {id}" and logs it.
3. Whoever has DB access runs one `UPDATE settings SET value='<id>' WHERE key='telegram_authorized_chat_id'` (or an admin.html field can be added later if this needs to be self-service).
4. From then on, every request checks `update.message.chat.id` (or `callback_query.message.chat.id`) against that setting and silently ignores anything that doesn't match.

---

## 3. Edge Function: `supabase/functions/telegram-bot/index.ts`

Structure mirrors `razorpay-webhook/index.ts`: no CORS, `createClient` with service_role, secret-header check first.

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const TG_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const secret = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
  if (secret !== Deno.env.get("TELEGRAM_WEBHOOK_SECRET")) {
    return new Response("Forbidden", { status: 403 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const update = await req.json();
  const msg = update.message ?? update.callback_query?.message;
  const chatId = msg?.chat?.id;
  if (!chatId) return new Response("ok", { status: 200 }); // ignore non-chat updates

  // Auth check
  const { data: authSetting } = await supabase.from("settings").select("value").eq("key", "telegram_authorized_chat_id").single();
  if (!authSetting?.value) {
    await tgSend(chatId, `Not authorized yet. Ask Rachnakar to approve chat_id: ${chatId}`);
    return new Response("ok", { status: 200 });
  }
  if (String(chatId) !== authSetting.value) {
    return new Response("ok", { status: 200 }); // silently ignore unknown users
  }

  // Load/create session
  const { data: session } = await supabase.from("telegram_sessions").select("*").eq("chat_id", chatId).single();
  const state = session?.state ?? "idle";
  const data = session?.data ?? {};

  // Route: text command, typed input, or button press (callback_query)
  const text = update.message?.text;
  const callbackData = update.callback_query?.data;

  if (text === "/start" || state === "idle") {
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
  } else if (callbackData?.startsWith("kiosk:")) {
    await handleKiosk(supabase, chatId, state, data, callbackData, text);
  } else if (callbackData?.startsWith("inv:")) {
    await handleInventory(supabase, chatId, state, data, callbackData, text);
  } else if (callbackData?.startsWith("godown:")) {
    await handleGodown(supabase, chatId, state, data, callbackData, text);
  } else {
    // typed free-text input for whatever step we're mid-flow on
    await handleTextInput(supabase, chatId, state, data, text);
  }

  if (update.callback_query) {
    await fetch(`${TG_API}/answerCallbackQuery`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id: update.callback_query.id }),
    });
  }

  return new Response("ok", { status: 200 });
});

async function tgSend(chatId: number, text: string, keyboard?: any) {
  await fetch(`${TG_API}/sendMessage`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, reply_markup: keyboard }),
  });
}

async function saveSession(supabase: any, chatId: number, state: string, data: object) {
  await supabase.from("telegram_sessions").upsert({ chat_id: chatId, state, data, updated_at: new Date().toISOString() });
}

async function showTopMenu(chatId: number) {
  await tgSend(chatId, "What would you like to do?", {
    inline_keyboard: [
      [{ text: "🛍️ Kiosk mode", callback_data: "kiosk:start" }],
      [{ text: "➕ Enter inventory", callback_data: "inv:start" }],
      [{ text: "📦 Godown check", callback_data: "godown:start" }],
    ],
  });
}
```

`handleKiosk`, `handleInventory`, `handleGodown`, `handleTextInput` are the three mode state machines — see section 4 below for the exact steps each covers. Each is a `switch(state)` that reads/writes `data` (the jsonb blob) and calls `tgSend`/`saveSession`, calling the real RPCs (`create_batch_units`, `claim_unit`, etc.) at the point the existing web flow would.

**Photo handling** (Enter Inventory mode): when a photo message arrives, `update.message.photo` is an array of sizes — take the largest, call `GET {TG_API}/getFile?file_id=...` to resolve a `file_path`, download from `https://api.telegram.org/file/bot{TOKEN}/{file_path}`, then `POST` those bytes to `${SB}/storage/v1/object/item-photos/{Date.now()}-telegram.jpg` with the service_role key — same target bucket/path pattern as `uploadFile()` in admin.html, just done server-side instead of browser-side.

---

## 4. State machine — step-by-step per mode

### Kiosk mode (`kiosk:*`)
| State | Bot shows | User does | Next state |
|---|---|---|---|
| `kiosk_pick_item` | Buttons: in-stock SKUs (name + available count), paged | Taps one | `kiosk_pick_unit` |
| `kiosk_pick_unit` | Buttons: available unit codes for that SKU | Taps one, or "add another item" loops to `kiosk_pick_item` | `kiosk_customer_name` |
| `kiosk_customer_name` | "Customer name?" | Types name | `kiosk_customer_wa` |
| `kiosk_customer_wa` | "WhatsApp number?" | Types number | `kiosk_payment_mode` |
| `kiosk_payment_mode` | Buttons: Cash / UPI Direct / Razorpay | Taps one | `kiosk_amount` |
| `kiosk_amount` | "Amount received?" (prefilled suggestion = total) | Types amount | `kiosk_confirm` |
| `kiosk_confirm` | Order summary + [Confirm] [Cancel] | Taps Confirm | writes sale, back to `idle` |

On confirm: increment `settings.inv_counter` (same counter `saveSale()` uses), insert into `sales` (mirroring the fields `saveSale()` sets — `inv`, `date`, `customer`, `items`, `total`, `paid`, `balance`, `pay_mode`, `delivery_mode:'offline'`, `shipping_status:'na'`, `created_by:'telegram_bot'`, `source:'telegram'`), call RPC `claim_unit(p_unit_id, p_sale_id)` per selected unit. Reply with the invoice as formatted text plus a `wa.me/{digits}?text=...` link (same deep-link pattern as `sendSaleWA()`) for her to tap and actually send.

### Enter inventory mode (`inv:*`)
| State | Bot shows | User does | Next state |
|---|---|---|---|
| `inv_pick_vendor` | Buttons: vendor list + "+ New vendor" | Taps one | `inv_item_name` |
| `inv_item_name` | "Item name?" | Types | `inv_item_material` |
| `inv_item_material` | "Material?" | Types | `inv_item_variant` |
| `inv_item_variant` | "Variant?" | Types | `inv_item_cost` |
| `inv_item_cost` | "Cost per piece (₹)?" | Types number | `inv_item_qty` |
| `inv_item_qty` | "Quantity?" | Types number | `inv_item_mrp` |
| `inv_item_mrp` | AI-suggested MRP (same Gemini call as `suggestPrice()`, if `gemini_key` set) + [Use this] or type custom | Taps or types | `inv_item_photos` |
| `inv_item_photos` | "Send 1-4 photos, then tap Done" | Sends photos, taps [Done] | `inv_item_return_check` |
| `inv_item_return_check` | "Any pieces defective — return to seller now?" [Yes] [No] | Taps | if Yes → collect qty/reason → writes `purchase_returns` + marks units `returned_to_vendor`; either way → `inv_confirm_item` |
| `inv_confirm_item` | "Save this item?" [Save] [Add another item] [Finish purchase] | Taps | Save/Add loops; Finish → `inv_payment_amount` |
| `inv_payment_amount` | "Amount paid?" | Types | `inv_payment_mode` |
| `inv_payment_mode` | Buttons: UPI / Cash / Bank Transfer / Cheque | Taps | `inv_payment_split` |
| `inv_payment_split` | "Split — Shalini ₹ / Meenakshi ₹?" | Types both | writes purchase, back to `idle` |

On finish: insert `purchases` row first (mirrors `saveSIEntry()`'s header fields), then per item: insert/update `inventory_skus`, upload photos to `item-photos`, call RPC `create_batch_units(p_sku_id, p_vendor_code, p_purchase_id, p_qty, p_photo_urls)`.

### Godown mode (`godown:*`)
Entry shows the two-button split resolved earlier: `[📊 End-of-day reconciliation]` / `[🔍 Spot check an item]`.

**EOD reconciliation path:**
| State | Bot shows | User does | Next state |
|---|---|---|---|
| `godown_eod_start` | Pulls today's `sales` (same query Daily Payment Summary uses), builds a list of distinct SKUs sold today | auto-advances | `godown_eod_item` |
| `godown_eod_item` | "《SKU name》 — sold {n} today, expected remaining: {x}. Matches?" [✅ Matches] [⚠️ Discrepancy] | Taps | Matches → next SKU in list (loops `godown_eod_item` until list exhausted, then `idle`); Discrepancy → `godown_discrepancy_type` |

**Spot check path:**
| State | Bot shows | User does | Next state |
|---|---|---|---|
| `godown_spot_search` | "Type an item name to search" | Types | shows matching SKUs as buttons | `godown_spot_item` |
| `godown_spot_item` | Same expected-count + match/discrepancy buttons as EOD | Taps | Matches → back to search; Discrepancy → `godown_discrepancy_type` |

**Shared discrepancy sub-flow:**
| State | Bot shows | User does | Next state |
|---|---|---|---|
| `godown_discrepancy_type` | Buttons: Missing / Damaged / Extra | Taps | `godown_discrepancy_note` |
| `godown_discrepancy_note` | "Optional note + photo, or tap Skip" | Types/sends/taps Skip | writes `vendor_issues` row, back to reconciliation/search loop |

Discrepancy insert: `vendor_issues` (`vendor_uuid` from the unit's originating purchase, `sku_id`, `unit_ids`, `issue_type` mapped from Missing/Damaged/Extra, `description` = the note, `issue_date` = today). "Damaged" additionally offers the same return-to-seller prompt as section 4's intake flow.

**AU demarcation** (resolved decision #4): every SKU button/label rendered by any of the three modes checks `sku.au_available` and prefixes `🇦🇺 ` to the button text when true — one shared helper function, applied everywhere a SKU name is shown.

---

## 5. Deploy steps (in order)

1. Message **@BotFather** on Telegram → `/newbot` → get the bot token.
2. Generate a random webhook secret yourself (e.g. `openssl rand -hex 32`).
3. You run (not me): `supabase secrets set TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=...`
4. I write `supabase/functions/telegram-bot/index.ts` per section 3, and run `supabase functions deploy telegram-bot`.
5. You (or I, since it's not a secret) call Telegram's `setWebhook`:
   ```
   curl -X POST "https://api.telegram.org/bot<TOKEN>/setWebhook" \
     -d "url=https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/telegram-bot" \
     -d "secret_token=<TELEGRAM_WEBHOOK_SECRET>"
   ```
   (This one needs the bot token in the URL, so you should run it yourself, or paste me just the confirmation once done rather than the token itself.)
6. Shalini messages the bot, we capture and approve her `chat_id` (section 2).
7. Test each mode per the verification list in the outline plan, with real-but-tiny test data, cleaned up after — same discipline as every other feature this session.

## 6. Suggested build order (test each stage before moving to the next)
1. **Skeleton**: webhook + secret check + auth check + `/start` menu only. Confirms the whole pipeline (Telegram → Edge Function → Supabase → back to Telegram) works before any business logic.
2. **Kiosk mode** — highest value, closest to already-tested `saveSale()` logic.
3. **Enter inventory + vendor returns** — needs the new schema from section 1 first.
4. **Godown mode** — the only genuinely new concept, build last once the item-lookup/session patterns from the other two modes are proven.
