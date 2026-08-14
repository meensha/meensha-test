# MEENSHA — Open Source E-Commerce Stack
## Project Brief v3 · Upload this file at the start of every Claude session

---

## About
Meensha (मीनशा) is a heritage Indian handloom saree brand. Owners: Shalini and Meenakshi. Sells via WhatsApp, pop-up exhibitions, and e-commerce website. Two markets: India (INR, primary) and Australia (AUD, secondary).

## Tech Stack
- **Frontend:** Static HTML (index.html + admin.html), GitHub Pages
- **Backend:** Supabase (project: `eglanmhhcccsuhbxywua`, Singapore region)
- **Key architecture:** Supabase URL + anon key in HTML (safe by design, RLS protects data). Sensitive keys (Anthropic, Razorpay, ShipRocket) in Supabase `settings` table, fetched after admin login only.
- **AI:** Anthropic API (Claude Sonnet) — invoice scanning, receipt parsing, product photo descriptions. Key in settings table.
- **Domain:** meensha.in · Test: github.com/meensha/meensha-test
- **WhatsApp:** India: +91 8709525218 · Australia: configurable in settings
- **Instagram:** @meensha_fabrics

## Roles (5 roles)
| Username | Password | Role | Display | Access |
|----------|----------|------|---------|--------|
| shameen | admin@123 | super_admin | Deedee | ALL + Settings, Users, Integrations, Site, Audit, Backup |
| shalini | shalini@123 | owner | Shalini | Home, Inventory, Overheads, Sale, Summary, P&L, Reviews, Offers, Site Content |
| meenakshi | meenakshi@123 | owner | Meenakshi | Same as Shalini |
| sales_in1 | sales@123 | sales_in | Sales India | Inventory (INR only, no costs) + New Sale (INR, own sales) |
| sales_au1 | sales@123 | sales_au | Sales AU | Inventory (AUD only, no costs/margins) + New Sale (AUD, own sales) |

Super admin configures module access per role (persisted to Supabase `settings`).
**sales_au CANNOT see:** cost price, INR sale price, margins, P&L, partner splits, overheads.

## Markets — India + Australia Only
- **India:** INR prices (sale_price). WA: wa_num_in. Checkout: Razorpay (when ON) or WhatsApp order.
- **Australia:** AUD prices (sale_price_aud = INR × aud_multiplier, rounded up to nearest 5). WA: wa_num_au. Checkout: ALWAYS WhatsApp enquiry (no online payment for AU).
- **Geo-detect:** IP lookup → IN = INR, anything else = AUD. Manual toggle 🇮🇳/🇦🇺 in nav.
- **Address override:** If browsing in ₹ but enters non-India shipping address → flips to AUD + AU WA number.
- **No USD/ROW.** Only two currencies, two WA numbers, two tracks.
<!-- FUTURE: When incorporated + Razorpay international enabled, AU customers can pay via POLi (AU bank transfer) or international cards through same Razorpay account. Fee: 3% + GST. Enable in Razorpay dashboard → International Payments → POLi. Same JS SDK, same webhook. -->

## Pricing
- AUD auto-fills: `roundUp5(sale_price × aud_multiplier)` where default aud_multiplier = 1.8
- `roundUp5 = Math.ceil(value / 5) * 5`
- AUD editable per item (owner can override auto-calculation)
- Multiplier configurable in admin Settings

## Item Naming / Batch System
Format: `{WEAVE}-{MATERIAL}-B{batch#}-{unit#}`
Example: `PAITH-COT-B01-03` = 3rd piece, 1st batch, Paithani Cotton

- Batch = one purchase from one supplier (carries supplier invoice #)
- Each unit has its own photo (uploaded during stock entry)
- Code auto-generates from name + material (first 5 + first 3 chars), editable
- Batch auto-increments per SKU

## Checkout Logic (toggle-gated)
- **Razorpay ON + India:** Cart → Login → Address → Razorpay (UPI/Card/NB) → Order saved
- **Razorpay OFF + India:** Cart → "Order on WhatsApp" (pre-filled msg with items + ₹ prices)
- **Australia (always):** Cart → "Enquire on WhatsApp" (pre-filled msg with A$ prices + AU WA)
- **ShipRocket ON:** Auto-create shipping order post-payment
- **ShipRocket OFF:** Manual shipping via admin
<!-- FUTURE: Razorpay international for AU. See Markets section comment. -->

## GST Logic
- Customer invoice: NEVER shows GST. Price is final/inclusive.
- Internal P&L / exports: owner toggle shows GST breakdown (default 5%, configurable)

## P&L Logic
- Revenue - Stock Cost = Gross Profit - Overheads = Net Profit
- Two partner settlement views: 50/50 AND proportional (by actual investment %)
- Overhead breakdown by category AND by tag
- Revenue breakdown by region (India ₹ / Australia A$ converted to ₹)

## Discount / Offer Engine
Owners create offers with:
- **Type:** % off, ₹ flat off, free item, free shipping
- **Conditions:** min cart value, specific SKUs/categories, date range, max uses
- **Region:** India only / Australia only / both
- **Free item:** select SKU or custom (e.g., "free blouse piece")
- **Ticker text:** AI-suggested, owner-editable before publishing
- **Display:** ticker bar + shop card badge + cart discount line + WA message
- Stored in `offers` table. Auto-expires past end date.

## Price Tag Printing
After stock entry, option to print labels matching Meensha's pre-cut A4 sticker sheets (105mm × 34mm, 16 per sheet):
- Left side: pre-printed मीनशा logo (already on stickers)
- Right side printed: Item name, batch code (PAITH-COT-B01-03), MRP ₹ / Sale ₹
- Optional: QR code linking to storefront item page
- Pure CSS @media print layout, window.print(). No PDF library.
- Reprint from Inventory tab anytime (select units, bulk print)

## Storefront Display
- 3+ units available → "In Stock" badge, hero photo only
- 2 available → "Only 2 left!" amber badge, BOTH unit photos shown
- 1 available → "Last piece!" red badge, that unit's photo prominently
- 0 available → "Sold Out" overlay + "Notify Me" button → saves to requests table

## Image Assets (16 files in repo root)
logo.svg, logo_eng.svg, meensha_logo_en.png, indus.png, roman.png, mughal.png, weavers_of_india.png, loom_threads.png, saree_ikat.png, saree_patola.png, saree_tussar.png, saree_ajrak.png, saree_gharchola.png, weaver_woman.png

---

## DATABASE TABLES

### Core (created in M1):
- `inventory_skus` — sku_code, name, material, tags[], cost, mrp, disc, sale_price, sale_price_aud, batch_counter, hero_photo, description
- `inventory_units` — unit_code, sku_id, purchase_id, batch, unit_num, photo_url, status (available/sold/reserved), sold_in_sale_id
- `purchases` — supplier_inv, date, seller, items[], total, payment{amount, shalini, meenakshi}
- `overheads` — date, cat, description, total, paid_by, shalini, meenakshi, tags[], note
- `sales` — inv, date, customer{}, items[], total, paid, currency, delivery_mode, shipping_status
- `offers` — name, type, value, conditions{}, region, free_item_sku, date_start, date_end, ticker_text, status, uses_count
- `users`, `settings`, `reviews`, `requests`, `popups`, `instagram_posts`

### Future (M11+):
- `customers`, `orders`, `cart`, `loyalty_pts`, `wishlist`, `addresses`

### Atomic Functions (in schema.sql):
- `claim_unit(unit_id, sale_id)` — prevents double-sell race condition
- `reserve_unit(unit_id)` — 15-min cart hold
- `release_expired_reservations()` — cleanup

---

## SECURITY RULES (every module must follow)

1. **SQL injection:** Impossible — Supabase REST API parameterises all queries. Never build SQL strings.
2. **XSS:** Sanitise ALL Supabase data before rendering. `function sanitise(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML;}` Use textContent over innerHTML where possible.
3. **Race conditions:** Use `claim_unit()` RPC for atomic unit selling. UPDATE WHERE status='available' RETURNING.
4. **API keys:** Supabase anon key in HTML (safe by design). All other keys in settings table, fetched after login.
5. **Price tampering:** WhatsApp = owner verifies manually. Razorpay = Edge Function creates order with server-side price.
6. **Input validation:** WA numbers: digits only 10-15 chars. URLs: validate format. Files: check MIME, max 5MB. Forms: trim, required checks.
7. **Sessions:** sessionStorage (tab-scoped). Future M11: Supabase Auth with JWT.

---

## AI FEATURES (Claude Vision API)

### 1. Invoice Scanner (M2 — Stock Entry)
- "📸 Scan Invoice" button. Photo of supplier bill (handwritten, Hindi/English/regional).
- AI extracts: seller, invoice #, date, items with weave_type + material_guess.
- Auto-generates SKU code. Flags duplicate purchases. Pre-fills form in yellow review mode.

### 2. Receipt Scanner (M4 — Expenses)
- "📸 Scan Receipt" button. Photo of expense bill.
- AI extracts: vendor, date, items, total. Auto-categorises (Delhivery → Shipping). Auto-tags (logistics, subscription, etc.).

### 3. Product Photo Describer (M2 — Stock Entry)
- Each piece photo analysed for weave type, colours, technique.
- Generates 2-line poetic storefront description. Cross-validates against form data.

### 4. Similar Item Matcher (M7 — future)
- Customer's "I want something like this" photo → matched against inventory.

### Implementation:
```javascript
let ANTHROPIC_KEY = '';
async function loadAIKey() {
  const rows = await sbQ('settings', '?key=eq.anthropic_key');
  if (rows?.length) ANTHROPIC_KEY = rows[0].value || '';
}
async function aiAnalyse(imageBase64, mediaType, promptText) {
  if (!ANTHROPIC_KEY) { toast('AI not configured','var(--red)'); return null; }
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({model:"claude-sonnet-4-20250514",max_tokens:1000,
      messages:[{role:"user",content:[
        {type:"image",source:{type:"base64",media_type:mediaType,data:imageBase64}},
        {type:"text",text:promptText}]}]})
  });
  const d = await r.json();
  return JSON.parse(d.content[0].text.replace(/```json|```/g,'').trim());
}
```
No AI key set → AI buttons hidden, manual entry works normally.

---

## MODULAR BUILD PLAN (15 modules, 12 sessions, 3 checkpoints)

### M1: DB migration + batch codes (admin)
Split inventory → inventory_skus + inventory_units. Batch code system.

### M2: Stock entry + photos + invoice AI + price tags (admin)
Add Stock redesign. Supplier inv #. Photo per unit. AUD auto-price. AI invoice scanner. AI product describer. Print price tags (A4 16-per-sheet, 105×34mm).

### M3: Settings + config + offers + roles (admin)
Settings (super_admin): WA numbers (IN/AU), AUD multiplier, integration toggles, role permissions, Anthropic key. Offer engine: create/edit offers with conditions + region + ticker text. Regional sales roles (sales_in, sales_au).

### ★ CHECKPOINT 1: Stock entry + settings + offers configured.

### M4: Overheads + expenses + receipt AI (admin)
Main tab with sub-tabs: Expenses (multi-tags, receipt AI) + Stock Purchase (editable splits). Register, filters, edit history, Excel+PDF export.

### M5: P&L + GST (admin)
Proportional + 50/50 split. Tag breakdown. Regional revenue split. GST internal toggle. Excel+PDF export.

### M6: Sale + unit selection + exports (admin)
Thumbnail grid unit picker. Photo on invoice. Atomic claim_unit(). Currency selector. Regional WA. sales_in/sales_au see only their currency. Price tag reprint. Excel+PDF exports.

### ★ CHECKPOINT 2: Full admin end-to-end.

### M7: Shop page (index)
Read from SKU+units tables. Urgency display (3+/2/1/0). Offer badges on eligible cards. Craft cards → filtered shop.

### M8: Dual currency + geo-detect (index)
IP geo → IN=INR, else=AUD. Manual toggle 🇮🇳/🇦🇺. Address override at checkout. WA routing to regional number.

### M9: Cart + WA order (index)
Cart drawer, localStorage, badge. Currency-aware. Offer discount applied in cart. WhatsApp order (Razorpay OFF) / Checkout placeholder (Razorpay ON).

### M10: Site content (admin + index)
Ticker CRUD (owners). Events carousel (upcoming+past, infinite loop). Instagram grid. Offer ticker auto-added.

### ★ CHECKPOINT 3: DEPLOY TO meensha.in. Revenue starts.

### M11: Customer auth (both) — needs OTP service
WA OTP login. customers table. Guest cart → sync. My Account.

### M12: Razorpay + ShipRocket (both) — needs incorporation + KYC
Razorpay (India only, toggle-gated). ShipRocket auto-ship. Edge Functions for webhooks.
<!-- FUTURE: Enable Razorpay international for AU (POLi). Same SDK, flip toggle. -->

### M13: Super admin dashboard (admin)
Dashboard: users, SKU tree, integration health (tech/fin/social stacks), audit log (last 5 logins: date/IP/location/actions), backup. Site: analytics. Integrations: 3-stack visibility + control (super_admin only, owners see read-only).

### M14+M15: Loyalty + backup (both)
Points (1pt/₹100, redeem 50pts=₹50). Tiers. Referral. Wishlist. Addresses. Backup: data + settings + regeneration prompt.

---

## SESSION PROMPTS

**Every session = Prompt A (validate design) → Prompt B (build) → Test → Deploy**

### Session 1 — M1+M2
**Upload:** admin.html + this brief

**Prompt A (validate first):**
```
I'm on M1+M2. Here is admin.html and the project brief.

BEFORE CODING — validate the design:
1. Data flow: Add Stock form → SKU row + unit rows + purchase row
2. Batch code generation: step-by-step example, what happens on repeat purchase
3. Photo-to-unit mapping: 6 photos for qty 6, which maps where
4. AI invoice scan: what gets pre-filled, what review mode looks like
5. Price tag layout: how 16 labels fit on A4 (105×34mm), what prints on each
6. Edge cases: SKU code conflicts, qty change after photos, AI returns bad JSON
Don't code yet.
```

**Prompt B (build):**
```
Design validated. Build it.

1. inventory_skus: sku_code, name, material, tags[], cost, mrp, disc, sale_price, sale_price_aud, batch_counter, hero_photo, description
2. inventory_units: unit_code, sku_id, purchase_id, batch, unit_num, photo_url, status, sold_in_sale_id
3. Add Stock: supplier inv #, batch auto-assign, code auto-generate, photo upload per qty, AUD = roundUp5(sale_price × multiplier)
4. AI: Scan Invoice button → Anthropic API → pre-fill in yellow review mode. Product photo → description + tags + cross-validate. Key from settings table.
5. Price tags: after save, "Print Tags" panel. Checkboxes per unit. A4 layout 16/page (105×34mm). CSS @media print. Item name + batch code + MRP/Sale price on right side.
6. Purchase register: expandable batch detail.
Sanitise all output. Atomic claim_unit() in schema.
```

**Test:** Add Paithani Cotton qty 6 → B01-01..06 created, photos linked, AUD auto-fills, tags print correctly. Add again → B02. AI scan works if key set.

**Deploy:** Upload admin.html to meensha-test repo → test at meensha.github.io/meensha-test/admin.html

---

### Session 2 — M3
**Upload:** admin.html (from S1) + brief

**Prompt A:**
```
I'm on M3. Validate:
1. Settings UI layout — where does it live?
2. WA numbers: how saved, how read by storefront
3. Offer engine: create flow, how conditions evaluate, how ticker auto-generates
4. Regional sales roles: what sales_in vs sales_au sees/doesn't see
5. Permission grid: how saving → affects next login
6. What if settings table empty (fresh install)?
Don't code yet.
```

**Prompt B:**
```
Build it.
Settings (super_admin only):
- WA Numbers: 🇮🇳 India (wa_num_in), 🇦🇺 Australia (wa_num_au). Test links. Validate digits.
- AUD Multiplier: default 1.8. Live preview.
- Toggles: Razorpay ON/OFF, ShipRocket ON/OFF. API key fields (masked+reveal).
- Anthropic AI key field.
- Role Permission Grid: modules × roles checkbox matrix → settings table.

Offer Engine:
- Create offer: name, type (% off/₹ off/free item/free shipping), value, conditions (min cart, SKUs, dates, max uses), region (india/australia/all), free_item_sku, ticker_text (AI-suggested, editable).
- Offer register: active/paused/expired. Edit/delete.
- Save to offers table.

Regional roles: sales_in (INR locked, no costs), sales_au (AUD locked, no costs/margins/P&L).
```

**Test:** Change multiplier → preview updates. Create offer → ticker text suggested. Login as sales_au → no costs visible. Toggle permissions → verify on re-login.

**Deploy:** Upload admin.html to meensha-test. ★ CHECKPOINT 1.

---

### Session 3 — M4+M5
**Upload:** admin.html (from S2) + brief

**Prompt A:**
```
I'm on M4+M5. Validate:
1. Overheads tab layout with both sub-tabs
2. Expense multi-tag storage + P&L tag breakdown calculation
3. Walk through P&L with numbers: 3 sales (₹15K), 2 purchases (₹8K split 60/40), 3 expenses (₹2K). Show both splits.
4. GST toggle: what changes in P&L vs export vs invoice
5. Receipt AI: 3 example receipts → what AI suggests
6. Regional revenue in P&L: how AU sales (A$) convert to ₹
Don't code yet.
```

**Prompt B:**
```
Build it.
Overheads main tab, two sub-tabs:
- Expenses: form + multi-tags (logistics/one-time/infra/subscription/repetitive) as JSON. Receipt AI scanner. Register with filters (category/paid by/tag/date). Summary + tag cards. Edit history (localStorage). Excel+PDF.
- Stock Purchase: all purchases, editable Sh/Me split, invested totals.

P&L: Revenue (by region) - Stock = Gross - Overheads = Net. Both 50/50 and proportional. Tag breakdown. GST toggle (internal only). Excel+PDF.
```

**Test:** Add expenses with tags → filter works. P&L math verified manually. GST toggle shows/hides correctly. Receipt scan works.

**Deploy:** Upload admin.html.

---

### Session 4 — M6
**Upload:** admin.html (from S3) + brief

**Prompt A:**
```
I'm on M6. Validate:
1. Unit selection: SKU → thumbnail grid → pick B01-04 → what happens
2. Race condition: two people sell same unit simultaneously
3. Invoice with unit code + photo
4. Currency selector: admin picks A$ for manual AU sale
5. What sales_in vs sales_au sees in New Sale
6. Price tag reprint from inventory
Don't code yet.
```

**Prompt B:**
```
Build it.
New Sale: thumbnail grid per SKU, pick unit, photo on invoice, claim_unit() atomic.
Currency: ₹/A$ selector. sales_in locked to ₹, sales_au locked to A$.
Offer discount auto-applied if eligible.
Summary: sales + purchase registers. Excel+PDF. GST column conditional.
Price tag reprint: select units from inventory → print.
```

**Test:** Pick B01-04 → sold → gone from grid. Invoice shows photo. Currency switch works. Reprint tags.

**Deploy:** Upload admin.html. ★ CHECKPOINT 2: full admin end-to-end.

---

### Session 5 — M7
**Upload:** index.html + brief

**Prompt A:**
```
I'm on M7. Validate:
1. Supabase query: SKUs + available unit count (avoid N+1)
2. Urgency display HTML/CSS for each state (3+, 2, 1, 0)
3. Offer badges on eligible shop cards — how matched
4. What if SKU has units across batches at different prices?
5. "Notify Me" flow
6. Mobile layout
Don't code yet.
```

**Prompt B:**
```
Build it.
Shop from inventory_skus + inventory_units. Urgency: 3+/2/1/0 with correct photos.
Offer badges from offers table (active + matching region). Craft cards → filter.
"Shop the Collection" exactly once. Sanitise all product data.
```

**Test:** Items at each stock level → correct display. Offer badge shows. Notify Me saves request.

**Deploy:** Upload index.html to meensha-test.

---

### Session 6 — M8
**Upload:** index.html (from S5) + brief

**Prompt A:**
```
I'm on M8. Validate:
1. Geo-detect flow + API failure fallback
2. Manual toggle UI in nav
3. When currency switches, what re-renders?
4. Address override: browsing INR, enters AU address → what happens
5. WA number routing per currency
Don't code yet.
```

**Prompt B:**
```
Build it.
Geo: ipapi.co → IN=INR, else=AUD. Toggle 🇮🇳/🇦🇺 in nav. localStorage persist.
WA links → wa_num_in or wa_num_au from settings.
Fallback: if sale_price_aud null → calculate from sale_price × multiplier.
```

**Test:** India IP → ₹. Toggle to 🇦🇺 → A$. WA links correct. Persists on reload.

**Deploy:** Upload index.html.

---

### Session 7 — M9
**Upload:** index.html (from S6) + brief

**Prompt A:**
```
I'm on M9. Validate:
1. Cart data structure in localStorage
2. Cart drawer layout
3. Currency switch → cart prices update (how, without re-fetch?)
4. WA message format for each currency
5. Offer discount in cart — how calculated and displayed
6. Razorpay ON vs OFF checkout button
Don't code yet.
```

**Prompt B:**
```
Build it.
Cart: nav icon + badge, drawer slides right, localStorage. Store both INR + AUD per item.
Offers: if active offer matches cart items, show discount line.
Checkout: Razorpay OFF → "Order on WhatsApp" (IN) / "Enquire on WhatsApp" (AU).
Razorpay ON → "Proceed to Checkout" placeholder for M12.
Address override: non-India address → flip to AUD + AU WA.
```

**Test:** Add 3 items, persist, currency switch, offer discount, WA message correct.

**Deploy:** Upload index.html.

---

### Session 8 — M10
**Upload:** admin.html (from S4) + index.html (from S7) + brief

**Prompt A:**
```
I'm on M10. Validate:
1. Ticker: admin → settings table → index.html reads → renders
2. Events carousel: infinite loop CSS for upcoming + past
3. Offer ticker: how auto-added offers appear alongside manual ticker messages
4. What owners can do vs super_admin
Don't code yet.
```

**Prompt B:**
```
Build both files.
Admin: ticker CRUD + events CRUD + Instagram CRUD in Home tab. Offer tickers auto-included.
Index: ticker infinite scroll (manual + offer messages merged). Events carousel. Instagram grid.
Owners manage ticker + events. Super admin manages all.
```

**Test:** Add ticker → appears on site. Add event → carousel shows. Offer ticker auto-appears.

**Deploy:**
```
Upload BOTH admin.html and index.html to meensha-test.

★ CHECKPOINT 3 — FULL SITE TEST:
[ ] Logo rotates, slideshow plays, ticker scrolls
[ ] Shop: correct stock levels, urgency badges, offer badges
[ ] Currency toggle works, WA links correct per region
[ ] Cart: add, persist, remove, offer discount applied
[ ] "Order on WhatsApp" → correct message + WA number
[ ] Events carousel loops
[ ] Admin: full stock → sale → P&L flow
[ ] All roles verified
[ ] Mobile works

IF ALL PASS → merge to main repo:
1. Go to github.com/meensha/meensha (main repo)
2. Upload: index.html, admin.html, all images, logo_eng.svg
3. Commit: "v2.0 — full platform launch"
4. Wait 2 min → meensha.in is live
5. Test on meensha.in
6. Site is earning revenue
```

---

### Session 9 — M11 (Customer Auth) — needs OTP service
**Upload:** both files + brief
```
Prompt A: Validate login flow, guest→logged-in cart sync, My Account layout.
Prompt B: WA OTP login, customers table, cart sync, My Account (orders, addresses, profile).
```

### Session 10 — M12 (Razorpay + ShipRocket) — needs incorporation + KYC
**Upload:** both files + brief
```
Prompt A: Validate payment flow, webhook handling, toggle behaviour.
Prompt B: Razorpay India-only (toggle-gated). ShipRocket auto-ship. Edge Functions.
```
<!-- FUTURE: Add Razorpay international for AU (POLi). Same integration, enable in dashboard. -->

### Session 11 — M13 (Super Admin Dashboard)
**Upload:** admin.html + brief
```
Prompt A: Validate dashboard cards, SKU tree, 3-stack integrations layout, audit log.
Prompt B: Dashboard + Site analytics + Integrations (tech/fin/social with health + credentials) + audit log.
```

### Session 12 — M14+M15 (Loyalty + Backup)
**Upload:** both files + brief
```
Prompt A: Validate points logic, tier thresholds, referral flow, backup contents.
Prompt B: Loyalty (1pt/₹100, tiers, referral). Wishlist. Backup (data + settings + regen prompt).
```

---

## CRITICAL RULES FOR CLAUDE

- Always start from uploaded file. Never patch from memory.
- Verify output ends with `</html>`.
- `'Shop the Collection'` appears exactly once in index.html.
- All JS in one `<script>` block before `</body>`.
- Supabase URL + anon key hardcoded (safe). Sensitive keys from settings table.
- Role checks: `['owner','super_admin'].includes(CU.role)` for edit/delete.
- Never exceed ~1800 lines per output file.
- No dangling onclick references.
- `roundUp5 = Math.ceil(value / 5) * 5`
- Sanitise ALL Supabase data before innerHTML rendering.
- Use claim_unit() RPC for atomic unit selling.
- No USD/ROW logic anywhere. India + Australia only.

---

## HOW TO START

1. **Create Claude Project:** claude.ai → Projects → "Meensha Build"
2. **Project instructions:** "Read MEENSHA_PROJECT_BRIEF.md first. Start from uploaded files only. Verify </html>. Max 1800 lines."
3. **Add this file** to project knowledge
4. **Run SQL:** Supabase → SQL Editor → paste setup/schema.sql → Run (once)
5. **Session 1:** Upload admin.html + this brief → paste Prompt 1A → validate → paste Prompt 1B → build

## COMPLETED MODULES
<!-- M1+M2: Done [date] — batch system + photos + AI scan + price tags -->
<!-- M3: Done [date] — settings + offers + regional roles -->