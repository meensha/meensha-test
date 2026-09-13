# Meensha — Running To-Do

Tracked here so nothing raised in a session gets lost. Git-tracked (syncs to gitea/GitHub); update as items land.

## Queued (not started)

- [ ] Instagram tiles on the storefront: the left-most tile should always show the actual latest post from Meensha's Instagram account (currently — confirm current behavior before building; may need Instagram Graph API access to pull real posts).
- [ ] SEO + Instagram growth initiative (large, multi-phase — see proposal in session transcript 2026-09-13):
  - Phase 0: Google Search Console setup — **still needs Dheeraj** to verify domain ownership (blocking any real traffic-number reporting; not something Claude can do alone).
  - ~~Phase 1: technical SEO~~ — **done 2026-09-13**, see below.
  - Phase 2: blog section + content calendar (ongoing, not started).
  - Phase 3: Instagram content drafts delivered to Shalini via bot for manual posting (ongoing, not started).
  - Needs: a supervisor → worker → QA → reporting-manager agent pipeline, each terminating after its task; daily morning-brief progress reporting; all actions recorded to syncthing/obsidian/gitea (and blog posts published) each phase. **The 4-hourly TODO-worker cloud routine (below) is the first piece of this — currently blocked on connecting GitHub to claude.ai.**
- [x] ~~Connect GitHub + create "Meensha TODO worker" routine~~ — **live 2026-09-13**: `trig_01CSksr3xMEajpixfNFjgj3g`, meensha-test2 (staging) only, reports to Shalini + MeenshaMonitor via `agent-report`. Fires at 08:30, 12:30, 16:30, 20:30, 00:30, 04:30 IST — daily rollup on the 08:30 IST run. https://claude.ai/code/routines/trig_01CSksr3xMEajpixfNFjgj3g

## Formatting notes for daily digests (apply next time touched)

- Don't use ⚠️ for the daily report — use a notepad/clipboard-style icon instead.
- List each flagged item on its own line, not comma-joined, for readability.

## Data quality (not a code bug, needs a decision)

- Dynamic shop categories (added 2026-09-13) surface real name-typo fragmentation in `inventory_skus.name` — e.g. "Mangalgiri" / "Mangalgri" / "Mangalriri", "Kalamkari" / "Kalamakari" each show as separate categories. Worth a data cleanup pass in admin.html's Inventory tab, or a future category-merging feature, if the sidebar gets too noisy.

## Done (recent, for reference)

- 2026-09-13: Kiosk "Share links/photos" (renamed from "Share this search") now offers two options: the existing filtered `?shop=` link, or a new flow that sends individual WhatsApp-ready messages per selected item (numbered list → multi-select → customer name → include-price choice → each item as its own photo+price+greeting+`?buy=` link, no wrapper text) — `supabase/functions/telegram-bot/index.ts`. **Needs manual deploy**: `supabase functions deploy telegram-bot`.
- 2026-09-13: Admin login attempts now log real IP + geolocation per attempt (new `log-auth-attempt` Edge Function; admin.html's Auth Log card already had unbounded history, now with IP/Location columns) and a new `auth-log-digest` cron posts a rolling since-last-report summary to MeenshaMonitor only, never Shalini's chat. **Needs manual deploy**: `supabase functions deploy log-auth-attempt`, `supabase functions deploy auth-log-digest --no-verify-jwt`, then run `setup/add_auth_log_location.sql` (adds columns, schedules the cron).
- 2026-09-13: Admin login page — Meensha logo now links back to index.html (was a dead image, staff had no way back to the main site from the login screen).
- 2026-09-13: Dynamic shop categories + live search + kiosk "Share this search" link; fixed deep-link scroll target and mobile category/grid overlap.
- 2026-09-13: Daily health digest now also flags SKUs with no photos, sent to Shalini's chat too (was monitor-only).
- 2026-09-12: AU stock-intake pending-cost tracking; fixed a serious region-awareness bug in the real (previously-dead-code-shadowed) approval function.
- 2026-09-11/12: Invoice PDF generation (pdf-lib), backfilled for all historical sales; fixed a 100%-reproducing ₹-symbol encoding bug; static UPI QR feature; Razorpay customer-record linking.
