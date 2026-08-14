# Meensha — Handoff / Current State (2026-08-11)

This is the **living status doc** — read this first in any new session. `MASTER_PLAN_2026-07-12.md` is the original approved plan and is now a historical snapshot only; almost everything below happened after it and isn't reflected there. This file doesn't replace the other detailed docs listed under "Reference docs" — it's the map that tells you which one to open.

## The one thing to understand before touching anything

Two separate deployment surfaces, don't conflate them:

1. **Supabase backend** (`eglanmhhcccsuhbxywua`) — schema, RPCs, Edge Functions, secrets. **One single project**, shared identically by every git site. Deploying an Edge Function (`supabase functions deploy <name>`) or running a SQL migration is live **immediately**, for real, regardless of what any git branch currently shows. Not gated by any `git push`.
2. **Two git repos** control the static `admin.html`/`index.html`/`about.html` files only:
   - `test2` → `github.com/meensha/meensha-test2` — staging (GitHub Pages)
   - `origin` → `github.com/meensha/meensha-test` — **production, meensha.in**

**As of this doc, `origin` (production) is only 2 commits behind `test2`** — almost the entire build (M1 through M9, M6, Razorpay, coupons, auth hardening, both Telegram bots, price tags, founders page, mobile nav) is already live on meensha.in, not sitting in staging. Verify with `git log origin/main..test2/main --oneline` before assuming something is "just staging."

**Local working copy may be ahead of both** — check `git log test2/main..HEAD --oneline` and `git status` before assuming what's committed/pushed is current.

**Supabase CLI works from this machine** — authenticated, linked to the real project (confirmed 2026-08-11). `supabase functions list --project-ref eglanmhhcccsuhbxywua` shows what's actually deployed. This means Edge Function deploys and SQL migrations can potentially be run directly rather than only handed to the user as manual steps — check this is still true before assuming otherwise, and confirm with the user before deploying to a live/production-affecting function.

## What's live right now (verified 2026-08-11)

**Database**: 43 SKUs in `inventory_skus`, `inv_counter` at 1038 (real sales have happened past the test data). `razorpay_enabled = true`. `wa_num_au` configured (`61488967995`). `coupons` table exists, 0 active rows currently.

**Edge Functions deployed & ACTIVE** (`supabase functions list`):
| Function | Purpose |
|---|---|
| `create-payment-link` | Razorpay dynamic checkout — creates a Payment Link for the exact cart total |
| `razorpay-webhook` | Confirms payment, converts reservation → sale, coupon consume |
| `telegram-bot` | India staff bot (Shalini) — Kiosk sales, Godown stock audit, stock check |
| `telegram-bot-au` | Australia staff bot (Meenakshi, `@meenshaozbot`) — Kiosk sales, draft-first Stock Intake, AU reports |

**Not yet deployed** (committed to git, needs `supabase functions deploy telegram-bot`): the India bot's Kiosk search fix (commit `55a4dc9`, 2026-08-11) — typing to search previously fell through every handler and silently dumped staff back to the main menu; now filters by name/material/variant like the storefront and AU bot already do.

## Feature inventory (chronological, git log is the ground truth)

- **M1+M2** (Jul 12–14): batch/unit inventory tracking (`inventory_skus`+`inventory_units`), vendor system, AI price suggestions (Gemini), invoice-scan-to-prefill, per-SKU photo gallery, duplicate-item detection.
- **M7+M8** (Jul 14): storefront reads real inventory, 🇮🇳/🇦🇺 currency toggle, cross-market badges.
- **M9** (Jul 14–21): cart with unit-level reservation hold, WhatsApp checkout, then later hardened with a visible countdown timer, auto-open-on-add, and coupon support wired into checkout.
- **M6** (Jul 15): Cash/UPI Direct/Razorpay payment modes, Daily Payment Summary.
- **Razorpay dynamic checkout** (Jul 15): real API integration pulled forward from M12 — KYC was already done, so this isn't the "paste a static link" stopgap, it's the real thing (`create-payment-link`/`razorpay-webhook` functions, `orders` table).
- **M3** (Jul 16): Settings panel (Connections tab in admin — WA numbers, AUD multiplier, Razorpay kill-switch, Telegram bot allowlists) + full coupon engine (code + WhatsApp-number lock, region-scoped, admin CRUD).
- **Auth security hardening** (Jul 17): see `MEENSHA_AUTH_SECURITY_HANDOFF.md` — password hashing moved server-side (bcrypt via RPC), no more plaintext-reachable-via-anon-key. Verify that doc's "already fixed" conclusion still holds if touching auth code.
- **Price tag printing** (Jul 18–19): sticker printing for physical stock; see `PRICE_TAG_PRINT_REDESIGN.md` for the approved redesign (batch tracking, quantity control, review-before-print) — check whether that redesign has actually been built yet or is still design-only.
- **Telegram bot — India** (Jul 18–19, revised Aug 11): Kiosk sales mode + Godown check (stock audit) mode. See `TELEGRAM_BOT_BUILD_PLAN.md` for the detailed spec this followed. Search bug fixed Aug 11 (not yet deployed — see above).
- **Telegram bot — Australia** (Aug 9): separate bot/token/allowlist from the India one, deliberately — Kiosk sales + draft-first Stock Intake (submissions don't touch live inventory until approved via a to-be-built admin.html review screen) + AU-scoped reports.
- **Storefront/UX polish** (Jul 21–28): photo compression on upload, mobile nav overflow fix, homepage collection grid (categories not priced items), founders/"Our Story" page rebuilt to match index.html exactly (nav, footer, ticker, currency toggle, cart — full parity), Instagram card styling, logo-as-home-button.
- **Admin — Connections tab** (Jul 23, extended Aug 9): central place for WA numbers, AUD multiplier, Razorpay kill-switch, Telegram bot allowlists (India + Australia, both support multiple chat IDs/accounts — just add rows), ticker/events/Instagram/reviews wiring to the storefront.

## Known gaps / open items

- **AU Telegram bot: coupon code entry is missing.** `consume_coupon` is wired up in the checkout code but nothing in the bot's flow ever sets `data.coupon_code` — dead code, not broken, just incomplete. Needs a code-entry step added to Kiosk mode if AU staff should be able to apply coupons via the bot.
- **AU bot Stock Intake approval screen doesn't exist yet.** `admin_approve_stock_intake_draft` RPC is built and callable, but there's no admin.html UI to review/approve/reject drafts — currently would need a direct RPC call to approve anything submitted via the AU bot's Stock Intake flow.
- **`MASTER_PLAN_2026-07-12.md` is stale** — kept as a historical record of the originally-approved plan, not updated since. Don't treat it as current.
- **Price tag redesign status unclear** — `PRICE_TAG_PRINT_REDESIGN.md` describes an approved redesign; check git log / actual admin.html `printTags()` behavior to confirm whether it's been built or is still pending.
- **India bot search fix not yet deployed** (see above) — committed, needs `supabase functions deploy telegram-bot`.

## Reference docs (don't duplicate their content here — open them directly)

- `MASTER_PLAN_2026-07-12.md` — original approved plan (historical, stale)
- `TELEGRAM_BOT_BUILD_PLAN.md` — India bot detailed spec/build plan
- `MEENSHA_AUTH_SECURITY_HANDOFF.md` — password/auth security investigation + fix confirmation
- `PRICE_TAG_PRINT_REDESIGN.md` — approved price-tag printing redesign (build status unclear, verify)
- `MEENSHA_MONITORING.md` — monitoring/uptime + AI daily-summary architecture (ties into the homelab, separate infra — mostly relevant if working on ops/monitoring, not the storefront itself)
- `meensha_bots_creds.md`, `meensha-monitor-credentials.md` — credentials, local-only, never paste contents into chat or commit

## Working conventions established this whole build (still apply)

- Commit locally, then `git push test2 main` for staging verification; push to `origin` (production, meensha.in) only when explicitly asked.
- SQL migrations and Edge Function secrets are handed to the user to run manually by default — **but the Supabase CLI now appears to work directly from this machine**, so check whether that's still true and whether direct deployment is preferred before defaulting to manual-steps instructions every time.
- Verify live DB schema directly (`fetch` a real row, check `Object.keys()`) before trusting any `.sql` file reflects deployed reality — this codebase has repeatedly had schema drift between what a migration file says and what's actually live.
- Test locally via `python3 -m http.server` + the Browser tool before pushing anything, logging in as `shameen`/`admin@123` (super_admin) for admin.html testing.
