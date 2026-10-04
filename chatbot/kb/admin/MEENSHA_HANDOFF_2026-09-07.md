# Meensha — Handoff / Current State (2026-09-07)

Session note — supersedes `MEENSHA_HANDOFF_2026-08-27.md` (in
`meensha-test/docs/`) as the living status doc. Everything from before
this session still holds; not repeated here.

## New this session

**Instagram checkout-link mode** (Shalini/India bot + admin.html) — rebuilt
mid-session after the first version was wrong (see below). Final design:
pick an item, type a caption, get back a `meensha.in/index.html?buy=<sku_id>`
link that auto-adds the item to a shopper's cart and opens checkout the
moment they tap it — no payment link created ahead of time, no placeholder
customer. `index.html`'s `loadShop()` handles the `?buy=` param.

**Voucher generation, both bots** — "🎟️ Create voucher" (India: Maintenance
submenu; AU: new "🎟️ Vouchers" top-level menu) calls the existing
`admin_create_coupon` RPC directly. Supports public or single-customer-locked
codes, region auto-set per bot.

**Event registration forms, both bots + admin.html** — new
`voucher_events` table + RPCs (`get_voucher_event`, `register_event_visitor`,
`admin_create_voucher_event` — see `setup/add_voucher_events.sql`, already
run). Staff picks a discount + region, gets a shareable
`register.html?event=<id>` link; each visitor who fills in name+WhatsApp
gets their own unique one-time coupon. Extends the pre-existing
stall-registration pattern (`register_visitor`/`register.html`) rather than
duplicating it — `register.html` now branches on a `?event=` param.

**AU (Meenakshi) bot fixes**:
- Coupon-code entry was completely missing from Kiosk mode (`consume_coupon`
  was wired but `data.coupon_code` was never set) — added the prompt step,
  wired the discount into the total.
- Self-service allowlist auto-approve cap raised 2 → 4.
- Payment mode gained a third option, **🔁 Other** — Meenakshi's actual main
  payment method isn't cash or card, so this lets her type a short note
  instead of forcing a fit. Same added to Shalini's bot.

**Session-summary activity digest** — MeenshaMonitor (`@meenshabot`) used to
only hear about sales, immediately, per-sale. Now both bots log *every*
action (sale, voucher, event form, stock intake, Insta/Razorpay link) to a
new `bot_activity_log` table (best-effort, `_shared/activityLog.ts`), and a
new cron function `activity-summary-digest` (every 10 min via pg_cron, see
`setup/add_bot_activity_log.sql`) posts one consolidated summary per chat
once that chat's most recent action is 10+ minutes old — a real break in
what they were doing, not a fixed timer. Replaces the old immediate
per-sale `notifyMonitor()` calls in both bot files (removed as dead code).

**Staff help guides** — `help-meenakshi.html` and `help-shalini.html`, real
public pages on the site (not Claude-account-gated), same design system,
content specific to each bot's actual menu structure. Linked from
`admin.html`'s new "❓ Help Guide" button, which routes to the right one
based on `CU.username`. Both explicitly clarify the customer-facing side
(the bot is staff-only; the customer only ever sees a WhatsApp message —
invoice, or for Shalini's bot optionally a Razorpay payment link).

**Login screen** — `admin.html`'s login dialog now shows the rotating
Meensha logo GIF instead of a plain text wordmark.

## Known gaps / open items

- AU (Meenakshi) bot doesn't have the Insta Link feature yet — deliberately
  deferred; only Shalini's bot has it so far.
- `activity-summary-digest`'s pg_cron job needs the SQL run (asked for
  during this session — confirm it landed if picking this up later).
- Everything else from `MEENSHA_HANDOFF_2026-08-27.md` still applies
  (AU bot Stock Intake approval screen still not in admin.html, price tag
  redesign status unclear, no visits/traffic tracking).

## Working conventions (still apply, reconfirmed this session)

- Three remotes stay in sync: commit → push `test2`, `origin`, `gitea`
  (Gitea occasionally needs a fresh access token — it's a stored HTTP
  credential in the `gitea` remote URL, not something else to debug).
- Edge Function deploys + `supabase secrets set` work directly via CLI.
  DDL still needs the user to run it manually in the Supabase SQL editor —
  copying the exact file to clipboard via `pbcopy` avoids paste-mangling
  (a `--` comment got silently turned into a stray `-` once this session
  by whatever the file was copied through).
- Type-check edge functions locally before deploying: `npm install
  typescript@5` in a scratch dir, then `tsc --noEmit --target es2020
  --module esnext --moduleResolution node --skipLibCheck <file>`, filtering
  out expected `Cannot find name 'Deno'` / module-resolution noise — this
  runtime has no Deno binary available, so this is the practical substitute.
