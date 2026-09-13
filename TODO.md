# Meensha — Running To-Do

Tracked here so nothing raised in a session gets lost. Git-tracked (syncs to gitea/GitHub); update as items land.

## Queued (not started)

- [ ] Kiosk share feature — rename to "Share links/photos", full spec (supersedes the earlier rough version above):
  - Two top-level options when staff tap it:
    1. **Send website filtered link** — the existing plain `?shop=<term>` link (already built).
    2. **Send individual WhatsApp messages (photo + price + personalized message)** — new flow:
      a. Bot shows the matching items as a numbered list (1, 2, 3, 4...).
      b. Staff type which ones to send — multiple allowed (e.g. "1,3,4"), each selected item becomes its own individual message later.
      c. Bot asks for the customer's name (for personalizing the message text).
      d. Bot asks whether to include the price in the message or not (staff choice, applies to all selected items in that batch).
      e. For each selected item, bot sends staff a ready copy-paste unit: item photo + price (if chosen) + a personalized greeting using the customer's name + a buy link (`?buy=<sku_id>`, which already auto-adds to cart — "straight to cart").
      f. The generated message text itself must be clean copy-paste — no wrapper/instructional text like "here's the message to copy" around it, just the raw text ready to forward.
  - Both options reachable from the same "Share links/photos" entry point in the kiosk item-picker.

- [ ] Admin login page (admin.html): clicking the Meensha logo should link back to the main site (index.html), not do nothing/stay put.
- [ ] Admin login attempts: log IP + location per attempt.
  - Full history always available in admin.html's tech-stack/health section (not time-limited).
  - Telegram daily report to MeenshaMonitor only shows activity since the last report (last 24h) — not full history, and not sent to Shalini's chat.
- [ ] Instagram tiles on the storefront: the left-most tile should always show the actual latest post from Meensha's Instagram account (currently — confirm current behavior before building; may need Instagram Graph API access to pull real posts).
- [ ] SEO + Instagram growth initiative (large, multi-phase — see proposal in session transcript 2026-09-13):
  - Phase 0: Google Search Console setup (needs Dheeraj to verify domain ownership — blocking, not something Claude can do alone).
  - Phase 1: technical SEO (sitemap.xml, robots.txt, meta descriptions, Open Graph tags, Product/LocalBusiness structured data) — safe to build once approved.
  - Phase 2: blog section + content calendar (ongoing).
  - Phase 3: Instagram content drafts delivered to Shalini via bot for manual posting (ongoing).
  - Needs: a supervisor → worker → QA → reporting-manager agent pipeline, each terminating after its task; daily morning-brief progress reporting; all actions recorded to syncthing/obsidian/gitea (and blog posts published) each phase.

## Formatting notes for daily digests (apply next time touched)

- Don't use ⚠️ for the daily report — use a notepad/clipboard-style icon instead.
- List each flagged item on its own line, not comma-joined, for readability.

## Data quality (not a code bug, needs a decision)

- Dynamic shop categories (added 2026-09-13) surface real name-typo fragmentation in `inventory_skus.name` — e.g. "Mangalgiri" / "Mangalgri" / "Mangalriri", "Kalamkari" / "Kalamakari" each show as separate categories. Worth a data cleanup pass in admin.html's Inventory tab, or a future category-merging feature, if the sidebar gets too noisy.

## Done (recent, for reference)

- 2026-09-13: Dynamic shop categories + live search + kiosk "Share this search" link; fixed deep-link scroll target and mobile category/grid overlap.
- 2026-09-13: Daily health digest now also flags SKUs with no photos, sent to Shalini's chat too (was monitor-only).
- 2026-09-12: AU stock-intake pending-cost tracking; fixed a serious region-awareness bug in the real (previously-dead-code-shadowed) approval function.
- 2026-09-11/12: Invoice PDF generation (pdf-lib), backfilled for all historical sales; fixed a 100%-reproducing ₹-symbol encoding bug; static UPI QR feature; Razorpay customer-record linking.
