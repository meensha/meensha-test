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

- [ ] Admin login attempts: log IP + location per attempt.
  - Full history always available in admin.html's tech-stack/health section (not time-limited).
  - Telegram daily report to MeenshaMonitor only shows activity since the last report (last 24h) — not full history, and not sent to Shalini's chat.
- [ ] Instagram tiles on the storefront: the left-most tile should always show the actual latest post from Meensha's Instagram account (currently — confirm current behavior before building; may need Instagram Graph API access to pull real posts).
- [ ] SEO + Instagram growth initiative (large, multi-phase — see proposal in session transcript 2026-09-13):
  - ~~Phase 0: Google Search Console setup~~ — **done 2026-09-13**: domain property `meensha.in` verified (DNS via GoDaddy), sitemap.xml submitted. Performance data (impressions/clicks/position) expected to populate within 2-4 days.
  - ~~Phase 1: technical SEO~~ — **done 2026-09-13**, see below.
  - Phase 2 (revised 2026-09-13, scope narrowed — no general blog/content-calendar): mine real category/keyword terms from `inventory_skus.name` (Mangalgiri, Kalamkari, Ikkat, etc. — same data already surfaced by the dynamic shop categories) to inform Instagram post topics and product labeling below. Not started.
  - Phase 3 (revised 2026-09-13): Instagram content, 2-3 posts/week, drafted for Shalini via bot for manual posting — content is new-stock-arrival announcements + event coverage, NOT generic blog posts. Not started.
    - Instagram → store click flow (confirmed free, no Meta charge — setup effort only), two tiers:
      - **Tier A (buildable now, no Meta approval needed)**: bio link (up to 5 links, no follower minimum) or Story link sticker (no follower minimum, available to all accounts as of 2026) pointing to the existing `?buy=<sku_id>` or `?shop=<term>` deep links, with UTM params (`utm_source=instagram&utm_medium=...`) appended for attribution once GSC/GA can see it.
      - **Tier B (needs Meta Commerce Manager catalog + review)**: native Product tags in posts/Reels/Stories, tappable inside Instagram. Catalog feed can be auto-generated from `inventory_skus` rather than entered manually. Worth bundling with the Instagram Graph API App Review pass above (same approval process, do once).
  - New (2026-09-13, from Instagram/SEO scoping conversation — not yet spec'd in detail):
    - "Trending" badge's Instagram-view-count suggestion signal is still blocked on Instagram Graph API (Insights) access — needs Instagram account converted to Business/Creator + linked to a Facebook Page, then Meta App Review (business verification, screencast, permission justification — can take days, not instant). Rate limit ~200 calls/hour, not a concern at Meensha's scale. Do this setup once, not per-feature. The sales-velocity half of the suggestion signal is already live (see Done below); a TODO comment in admin.html's `skuSoldRecent()` marks where the view-count signal would plug in once this is unblocked.
    - Not CSR framing — this is Meensha's core mission (weaver upliftment/fair trade), not an add-on program. Blog scoped narrowly to the existing **Artisans** section (`index.html#weavers`) only — periodic posts about weaver upliftment activity, not a general blog. Not started.
  - Needs: a supervisor → worker → QA → reporting-manager agent pipeline, each terminating after its task; daily morning-brief progress reporting; all actions recorded to syncthing/obsidian/gitea (and blog posts published) each phase. **The 4-hourly TODO-worker cloud routine (below) is the first piece of this — currently blocked on connecting GitHub to claude.ai.**
- [x] ~~Connect GitHub + create "Meensha TODO worker" routine~~ — **live 2026-09-13**: `trig_01CSksr3xMEajpixfNFjgj3g`, meensha-test2 (staging) only, reports to Shalini + MeenshaMonitor via `agent-report`. Fires at 08:30, 12:30, 16:30, 20:30, 00:30, 04:30 IST — daily rollup on the 08:30 IST run. https://claude.ai/code/routines/trig_01CSksr3xMEajpixfNFjgj3g

## Formatting notes for daily digests (apply next time touched)

- Don't use ⚠️ for the daily report — use a notepad/clipboard-style icon instead.
- List each flagged item on its own line, not comma-joined, for readability.

- [ ] sitemap.xml currently only lists 3 static pages (home, about, register) — no individual shop/product pages or the (future, Artisans-section-only) CSR posts. Worth expanding once that content exists, or sooner if product-page indexing matters.

## Data quality (not a code bug, needs a decision)

- Dynamic shop categories (added 2026-09-13) surface real name-typo fragmentation in `inventory_skus.name` — e.g. "Mangalgiri" / "Mangalgri" / "Mangalriri", "Kalamkari" / "Kalamakari" each show as separate categories. Worth a data cleanup pass in admin.html's Inventory tab, or a future category-merging feature, if the sidebar gets too noisy.

## Done (recent, for reference)

- 2026-09-13: "NEW" (added to `inventory_skus` within 14 days, via `created_at`) and "Trending" product image badges on the storefront shop grid (`index.html`'s `renderShopGrid`). Trending is a staff-set flag (new `inventory_skus.trending` column, migration `20260913140000`) toggled in admin.html's Inventory tab, with a suggestion nudge (💡) when a SKU has ≥3 units sold in the last 14 days (computed from existing `inventory_units` sold/updated_at data) — staff can accept or ignore; the toggle is always the final word. Instagram view-count half of the suggestion signal not built (see Queued above — blocked on Meta API access).
- 2026-09-13: Confirmed the `?shop=`/`?buy=` deep links already pass through extra UTM params (`utm_source`, `utm_medium`, etc.) safely — both use `URLSearchParams(location.search).get(...)`, which ignores unrelated keys. No code change needed.
- 2026-09-13: Admin login page — Meensha logo now links back to index.html (was a dead image, staff had no way back to the main site from the login screen).
- 2026-09-13: Dynamic shop categories + live search + kiosk "Share this search" link; fixed deep-link scroll target and mobile category/grid overlap.
- 2026-09-13: Daily health digest now also flags SKUs with no photos, sent to Shalini's chat too (was monitor-only).
- 2026-09-12: AU stock-intake pending-cost tracking; fixed a serious region-awareness bug in the real (previously-dead-code-shadowed) approval function.
- 2026-09-11/12: Invoice PDF generation (pdf-lib), backfilled for all historical sales; fixed a 100%-reproducing ₹-symbol encoding bug; static UPI QR feature; Razorpay customer-record linking.
