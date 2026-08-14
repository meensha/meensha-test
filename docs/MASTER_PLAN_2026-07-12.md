# MEENSHA MASTER PLAN
## Dated: 12 July 2026
## Simple to operate · Simple to maintain · Easy to hand over

---

## Zero-Cost Confirmation

Build and run cost: **₹0**. GitHub Pages (hosting), Supabase free tier (DB/storage), Gemini free tier (AI benchmarking + invoice scan), ipapi.co free tier (geo-detect), CSS print for price tags on existing pre-cut sticker sheets (105×34mm, 16/sheet, pre-printed मीनशा logo).

Only ongoing costs: Razorpay 2% per successful online transaction (deducted from payment), domain renewal ~₹800/yr (already paying).

Free tier watch-outs: Supabase pauses after ~1 week idle (click Resume, no charge); 1GB photo storage (~2,000+ photos); Gemini 15 req/min (ample).

---

## Current Progress Summary

### Done ✅
| Item | Status |
|------|--------|
| Supabase schema | All tables + RPCs deployed |
| April 2026 backup | 39 items, 13 sales, 14 overheads, 8 purchases restored |
| admin.html | 3142-line build — Vendors tab, full inventory |
| meensha-test2 | Staging at meensha.github.io/meensha-test2 |

### Blocked 🔴
Supabase paused → resume at supabase.com first

---

## Design Decisions (Confirmed)

| Feature | Decision |
|---------|----------|
| AUD benchmark | Gemini free tier — searches Etsy/boutiques → suggests just-below-market A$ |
| INR benchmark | Gemini free tier — searches Myntra, iToKri, Jaypore for India price range → suggests INR |
| Git remotes | Keep origin/test2/prod |
| More countries | Hardcode India+AU now, expansion point for later |
| ShipRocket | Build M12 after KYC |
| Coupon lock | Per-customer (name + WA match at checkout) |
| AU landing | Simple flag toggle, same layout |

---

## Storefront: Dual Market Visibility (M7+M8)

### India view (INR):
- Full India catalogue in ₹
- "Available Internationally" badge on items with AUD price set
- Below each such item (or collapsible): "Also available in Australia — A$XX"

### Australia view (AUD):
- AU-available items in A$ as primary catalogue
- Below or collapsible: "Also available in India — ₹XX" for India-available items
- Shipping note toggle (owner sets in Settings: show/hide)

### Item availability flags (per SKU in admin):
- ✅ `india_available` — show in INR catalogue (default ON)
- ✅ `au_available` — show in AUD catalogue (owner sets, default OFF until AUD price added)
- Either Shalini or Meenakshi can toggle both flags at any time
- Super_admin can bulk-set

---

## AI Price Benchmarking (M2 — Stock Entry)

Powered by Gemini free tier. Triggered when owner adds a new SKU.

### For India pricing (INR):
- Searches: Myntra, iToKri, Jaypore, Craftsvilla for similar weave + fabric
- Shows: `💡 Similar on Myntra/iToKri: ₹3,200–4,500 · Suggested: ₹3,150`
- Comment only — owner accepts or types their own price

### For Australia pricing (AUD):
- Searches: Etsy, similar boutiques for Indian handloom + fabric type
- Shows: `💡 Similar on Etsy: A$85–110 · Suggested: A$79`
- Comment only — owner accepts or overrides

Both suggestions are non-blocking — owner always has final control.

---

## Coupon Codes (M3)

- Admin creates codes: e.g. `VIP-001` → assigned to "Priya Sharma / +91 98765..."
- At checkout: customer enters code + their WA number → Supabase validates match
- Max 1 use, region-locked (India/AU/both), date range
- Admin sees: code, assigned customer, used/unused, timestamp

---

## Payment Options

| Mode | When | Fee |
|------|------|-----|
| Cash | Events | 0% |
| UPI Direct | Events + India | 0% |
| Razorpay | India online | 2% (Meensha absorbs) |
| WhatsApp enquiry | AU always | 0% |

Daily admin summary: Cash / UPI / Razorpay breakdown → cross-verify with Razorpay dashboard.

---

## Build Order

| # | Module | What you get |
|---|--------|--------------|
| 🔴 | Resume Supabase | Everything unblocks |
| 1 | M1+M2 | Batch tracking, photos, INR+AUD benchmark via Gemini |
| 2 | M7+M8 | Storefront: real inventory, currency toggle, cross-market badges |
| 3 | M9 | Cart + WhatsApp order |
| 4 | M6 | New Sale: Cash/UPI/Razorpay + daily summary |
| 5 | M3 | Settings + coupon engine (per-customer lock) |
| ⭐ | **GO LIVE** | meensha.in earning revenue |
| 6 | M12 | Razorpay embedded + ShipRocket (after KYC) |
| 7 | M5 | Full P&L with Razorpay fee breakdown |

---

## Handover to Professional Designer

- **Colors/fonts:** CSS variables in first 20 lines — 10 value changes = full rebrand
- **Config:** All in Supabase `settings` table — no code edit needed for WA numbers, multipliers, toggles
- **Schema:** `setup/schema_combined.sql` self-documents the data model
- **No build step** — open file, edit, save, push. Any developer works on it immediately

---

## Immediate Next Actions

1. Resume Supabase → supabase.com → project → Resume
2. Test admin → meensha.github.io/meensha-test2/admin.html (39 items should load)
3. Set up Razorpay Payment Links manually (zero code, for next event)
4. Start M1+M2 build session
