# Telegram Bot — Detailed Build Plan (Shalini, v1)

Follows the approved broad outline (see chat history). This is the build-ready spec: exact schema, exact file, exact state machine, exact deploy steps. Read this alongside `supabase/functions/razorpay-webhook/index.ts` — that function is the template this one follows.

## 0. Where this lives relative to test2/origin — important, easy to get wrong

This project has two separate deployment concepts that are easy to conflate:

- **The Supabase backend** (`eglanmhhcccsuhbxywua` — schema, RPCs, Edge Functions, secrets) is **one single project**, shared identically by both git sites. There is no "staging backend" vs "production backend." When the bot's Edge Function is deployed via `supabase functions deploy telegram-bot`, it is immediately live — the same instant, for real, regardless of which git branch/site currently reflects admin.html/index.html changes. Deploying the bot is not gated by, or connected to, any `git push`.
- **The two git sites** (`test2` = meensha-test2 staging, `origin` = meensha-test = real production, meensha.in) only affect the static `admin.html`/`index.html` files. This matters here because of one specific piece: the **"↩ Return to seller" button** (section 1) needs to be added to admin.html's web UI, not just the bot. That change follows the normal flow already used all session — commit, push to `test2`, verify in-browser, then push to `origin` only when you explicitly ask for it (origin is still the real live site, same caution as always).
- **Practical order for this feature**: deploy the Edge Function + run the SQL migration first (backend, safe, instantly live but inert until something calls it) → build and test the bot end-to-end against that backend → separately, make and push the small admin.html web-UI addition for returns through the normal test2 → origin flow. The bot going live doesn't require any git push at all; the admin.html return-button addition does, and follows the existing pushed-only-when-you-say-so rule.

---

## 1. Schema changes (new SQL file: `meensha-test/setup/add_telegram_bot.sql`)

Two new tables, added via migration (exact SQL omitted here — see the migration file itself for the literal definitions):

- **`telegram_sessions`** — holds conversation state (`chat_id`, current `state`, a `data` jsonb blob) between messages, since the Edge Function is stateless per-invocation and has to remember where the user is mid-flow somewhere. Locked down the same way as other service-role-only tables in this project: only the bot's own Edge Function (authenticated as service_role) can read or write it — no client-facing access at all.
- **`purchase_returns`** — new table for vendor returns (defective pieces sent back to the supplier). A new `returned_to_vendor` status was added to `inventory_units.status`. Unlike the session table, this one is a normal operational table (same access pattern as the rest of the app's day-to-day data) since it isn't sensitive the way credentials or coupons are — both `admin.html` and the bot write to it.

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

Structure mirrors `razorpay-webhook/index.ts`: no CORS, connects to Supabase with the service-role key, and checks a shared secret before doing anything else (the exact comparison logic is intentionally not reproduced here — see the deployed function source for the literal check).

At a shape level, each incoming webhook call:
1. **Verifies the request actually came from Telegram** — Telegram is configured to send a secret token on every webhook call, and the function rejects anything that doesn't present the matching value, before touching the database or sending any reply.
2. **Resolves the chat** from the incoming update (a plain message, or a button-press "callback query") and bails out immediately on anything that isn't a real chat.
3. **Checks the chat against the allowlist** — unapproved chats get told their chat ID so an admin can approve them; already-known-but-unapproved chats are silently ignored.
4. **Loads (or creates) that chat's session row** — the conversation's current `state` and accumulated `data`, since the function itself has no memory between calls.
5. **Routes the update** — a fresh `/start` or an idle session shows the top-level menu; a button press routes into the matching mode's handler (Kiosk / Enter inventory / Godown check); anything else is treated as free-text input for whatever step the chat is currently mid-flow on.
6. Sends its reply via Telegram's `sendMessage` API, and acknowledges any button press so Telegram stops showing a loading spinner on it.

The three mode handlers (`handleKiosk`, `handleInventory`, `handleGodown`) are `switch`-on-state state machines — each step reads the session's `data`, does its work, writes the next `state`/`data`, and replies. See section 4 below for the exact steps each mode covers.

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
