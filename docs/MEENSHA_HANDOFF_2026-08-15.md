# Meensha — Handoff / Current State (2026-08-15)

This is the **living status doc** — read this first in any new session. Supersedes `MEENSHA_HANDOFF_2026-08-11.md` (kept as a historical snapshot). `MASTER_PLAN_2026-07-12.md` is the original approved plan and is even more stale.

## The one thing to understand before touching anything

Two separate deployment surfaces, don't conflate them:

1. **Supabase backend** (`eglanmhhcccsuhbxywua`) — schema, RPCs, Edge Functions, secrets. **One single project**, shared identically by every git site. Deploying an Edge Function or running a SQL migration is live **immediately**, not gated by any `git push`.
2. **Three git remotes** control the static files:
   - `test2` → `github.com/meensha/meensha-test2` — staging (GitHub Pages)
   - `origin` → `github.com/meensha/meensha-test` — **production, meensha.in**
   - `gitea` → self-hosted (`meensha-ecom`) — complete source-of-truth mirror (code + this `docs/` folder). Push with `git -c http.sslVerify=false -c http.extraHeader="Host: gitea.home.bhartis" push gitea main`.

**As of this doc, all three remotes are in sync at the same commit** (`5e19999`) — nothing is sitting in staging-only. Verify with `git log origin/main..test2/main --oneline` (should be empty) before assuming otherwise.

**Supabase CLI works from this machine, confirmed repeatedly** — `supabase functions deploy <name> --project-ref eglanmhhcccsuhbxywua` and `supabase secrets set KEY=value --project-ref ...` both work directly, no manual dashboard steps needed. Raw SQL/DDL still needs the user to run it in the Supabase SQL editor — no working DB password/connection string is available to this session, so `CREATE TABLE`/`ALTER TABLE`/`CREATE FUNCTION` migrations get hand-written as `setup/*.sql` files and handed over each time.

**Two Supabase API keys exist and are easy to confuse**: `meensha-monitor-credentials.md`'s `SUPABASE_SERVICE_KEY` is actually mislabeled — decode the JWT and it's `"role":"anon"`, not service_role. The real service_role key comes from `supabase projects api-keys --project-ref eglanmhhcccsuhbxywua -o json`. Using the anon key against an RLS-locked table with zero policies silently "succeeds" (200/204) while doing nothing — this bit a cleanup step this session (see Known gaps).

## What's live right now (verified 2026-08-15)

**Edge Functions deployed & ACTIVE**:
| Function | Purpose |
|---|---|
| `create-payment-link` | Razorpay dynamic checkout |
| `razorpay-webhook` | Confirms payment → sale, coupon consume |
| `telegram-bot` | India staff bot (`@meenshashalbot`, Shalini) |
| `telegram-bot-au` | Australia staff bot (`@meenshaozbot`, Meenakshi) |
| `start-customer-signup` | New — customer signup step 1, emails OTP |
| `verify-customer-signup` | New — verifies signup OTP, logs in |
| `request-password-reset` | New — emails password-reset OTP |
| `verify-password-reset` | New — verifies reset OTP, sets new password |
| `daily-health-check` | New — website/Supabase/Razorpay/GitHub status, posts to MeenshaMonitor |

Two functions from the M11 first-draft (per-login WhatsApp OTP) were built, then superseded same-day and removed: `send-customer-otp`, `verify-customer-otp` — never actually deployed live, confirmed via `supabase functions list` before deleting.

## Major feature: Customer login (M11) — built and live 2026-08-15

Redesigned mid-build after realizing WhatsApp OTP costs money (paid Business API provider) while email OTP is free (Resend, 3,000/month free tier):

- **Signup**: WA number + email + name + password. Email OTP verifies the address before the account is usable.
- **Login**: WA number *or* email + password. No OTP at routine login.
- **Forgot password**: email OTP → set new password.
- WA number stays the account's real identity — it's what `get_my_orders` matches against existing `sales`/`orders` rows, unchanged from the original design. Email is a second unique identifier + free OTP delivery address, not a replacement.
- Schema: `customers` (added `email`, `password_hash`, `email_verified_at`), `customer_otp` (now keyed by `email`+`purpose` ∈ signup/reset, not `wa`), `customer_sessions` (unchanged). See `setup/add_customer_auth.sql` — already run live.
- `RESEND_API_KEY` secret is set (real key, live account). `EMAIL_FROM` not yet customized — still using Resend's shared testing sender, which **only delivers to the Resend account's own registered email** (`meensha.fabrics@gmail.com`) until a real domain is verified at resend.com/domains. **This is the main open gap** — real customers can't receive signup/reset emails yet until that domain verification happens.
- Storefront UI: login/signup/forgot-password modal in `index.html`, "My Account" order history, review-submission form gated to logged-in customers with a delivered order. Checkout is **not** gated on login (deliberate choice — see Known gaps).

## Major feature: MeenshaMonitor (`@meenshabot`) wired up — built 2026-08-15

Previously a provisioned-but-unused bot token (per `MEENSHA_MONITORING.md`'s original plan, never actually built). Now:
- Every India and AU sale posts a one-line copy to MeenshaMonitor (`notifyMonitor()` in both `telegram-bot`/`telegram-bot-au`), best-effort/non-blocking.
- `daily-health-check` posts a daily digest (website/Supabase/Razorpay/GitHub+Pages status) — needs `setup/add_daily_health_check_cron.sql` run (pg_cron, `--no-verify-jwt` deploy already done) to actually run on schedule; can also be triggered manually via `curl -X POST https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/daily-health-check`.
- **Still blocked**: nobody had ever messaged `@meenshabot` as of this doc, so `settings.telegram_monitor_chat_id` is unset and both features silently no-op (by design — never blocks a real sale). Whoever owns notifications needs to message `@meenshabot` once; then set that chat_id.
- Explicitly out of scope this pass: visit/traffic counts — no `events`/analytics table exists on the storefront at all yet. Real follow-up item, not wired into the digest.

## Major feature: AU bot self-service allowlist — built 2026-08-15

The first 2 distinct chats to message `@meenshaozbot` auto-approve themselves (no admin step), using their Telegram name as the label. Past 2 active users, new chats still need manual admin approval via `admin.html`'s Connections tab, same as before. Justification: every AU sale is already mirrored to MeenshaMonitor regardless of who made it, so there's an audit trail even without manual vetting for the first two. **Real tradeoff, not just convenience**: those two get full write access (record sales, run Stock Intake), not read-only — worth remembering if the bot link is ever shared further than intended.

## Major feature: Public + category-scoped coupons — built 2026-08-15

The coupon engine was WA-locked (one code = one pre-assigned customer) and whole-cart-only. Extended for the FREEDOM200 Independence Day promo:
- `coupons.customer_wa`/`customer_name` now nullable — NULL means a public, reusable code anyone can type (no WA entry needed).
- New `coupons.category_filter` column — case-insensitive substring matched against cart item names (same convention as the storefront's own `matchF()` category filter). NULL still means whole-cart, unchanged for every pre-existing coupon.
- Public codes never flip `used` — stay reusable through `valid_until`. **No per-customer redemption cap in this pass** — same person could reuse a public code more than once. Acceptable for a time-boxed launch promo; revisit if abuse becomes a real concern.
- `admin.html`'s Coupons tab now has a Category Filter field; leaving Customer Name/WhatsApp blank creates a public code instead of failing validation.
- Live coupon created: `FREEDOM200`, ₹200 flat off, category filter `dupatta`, India region, valid 2026-08-15 → 2026-08-18. **Catalog reality check**: only one live SKU actually matches — "MADHUBANI DUPATTA" (1 unit in stock) — not the Kalamkari dupattas the promo caption describes. Verify Kalamkari stock gets added (name containing "dupatta") before/while the promo runs, or customers adding a Kalamkari-named item that doesn't literally say "dupatta" won't trigger the discount.

## Other fixes this session

- **Nav**: account icon was an illegible 👤 emoji — replaced with a bespoke gold loom/weaver SVG silhouette, bigger + bolder, with a dynamic tooltip ("Log In" / "My Account — name"). Separate circular cart-bag icon removed entirely — merged into the "Shop Now" button itself (shows the item-count badge, and now opens the cart drawer directly instead of navigating to the shop grid once something's in it). Applied to both `index.html` and `about.html` for consistency.
- **admin.html**: Sales edit modal (✏️ button) can correct customer name/WA/date/amount-paid/notes, but *not* line items/total/pay_mode — those still need delete-and-re-enter. Flagged, not yet built.
- **Found and fixed a stale git-tracking bug**: an earlier commit this session (`f105af7`) claimed to delete `send-customer-otp`/`verify-customer-otp` but never actually staged the deletion (`git add` was scoped to only the new files, not `git rm` on the old ones) — the dead files sat tracked-but-deleted-on-disk for several commits. Confirmed via `supabase functions list` that neither was ever live-deployed before cleaning it up, so no live-backend impact.

## Known gaps / open items

- **Resend sender domain not verified** — signup/reset emails only deliver to the Resend account owner's own email until `EMAIL_FROM` points to a verified domain. Blocks real customer signup right now.
- **MeenshaMonitor chat_id unset** — sale-copy and health-digest features are both fully wired and deployed, but silently inert until someone messages `@meenshabot` once and the chat_id gets written to `settings.telegram_monitor_chat_id`.
- **`add_daily_health_check_cron.sql` run status unconfirmed** — needs to be (re-)verified that the pg_cron job actually exists and is scheduled, not just that the function works when curled manually.
- **AU Telegram bot: coupon code entry is still missing** from the Kiosk flow (`consume_coupon` wired, nothing sets `data.coupon_code`) — unchanged from the 08-11 doc.
- **AU bot Stock Intake approval screen still doesn't exist** in `admin.html` — unchanged from the 08-11 doc.
- **Price tag redesign status still unclear** — unchanged from the 08-11 doc, not investigated this session.
- **No visits/traffic tracking exists** — flagged as a real follow-up if a "how many visits" style health-digest metric is wanted later; needs a new `events` table + frontend instrumentation, deliberately out of scope for the health-check build this session.
- **Coupon anti-fraud**: public coupons have no per-customer redemption cap (see above) — fine for now, revisit if it becomes a real problem.
- **Sales edit modal** can't correct line items/total/pay_mode — delete-and-re-enter only, flagged to the user, not yet built.

## Reference docs (don't duplicate their content here — open them directly)

- `MASTER_PLAN_2026-07-12.md` — original approved plan (historical, stale)
- `TELEGRAM_BOT_BUILD_PLAN.md` — India bot detailed spec/build plan
- `MEENSHA_AUTH_SECURITY_HANDOFF.md` — password/auth security investigation + fix confirmation (staff auth, not customer auth)
- `PRICE_TAG_PRINT_REDESIGN.md` — approved price-tag printing redesign (build status unclear, verify)
- `MEENSHA_MONITORING.md` — original monitoring/uptime + AI daily-summary architecture plan (mostly superseded by the simpler pg_cron + MeenshaMonitor approach actually built this session — the original doc's homelab/Kuma/Ollama plan was never built)
- `meensha_bots_creds.md`, `meensha-monitor-credentials.md` — credentials, local-only, never paste contents into chat or commit (and note the anon/service_role mislabeling above)

## Working conventions established this whole build (still apply)

- Commit locally, then `git push test2 main` for staging verification. This session, production (`origin`) and Gitea got pushed the same batch each time too, once explicitly told to "make it live" — confirm that's still the desired cadence going forward rather than assuming it by default.
- SQL migrations (DDL) still need the user to run them manually in the Supabase SQL editor — no DB password available to this session. Edge Function deploys and `supabase secrets set` work directly via CLI.
- Verify live DB schema directly (`fetch` a real row, check `Object.keys()`) before trusting any `.sql` file reflects deployed reality.
- Test locally via `python3 -m http.server` + the Browser tool before pushing anything.
- Before treating a "cleanup"/DELETE API call as successful, confirm which key was used — the anon key silently no-ops against RLS-locked tables with no policies.
