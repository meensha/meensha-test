# Meensha — Handoff / Current State (2026-08-27)

Session note — supersedes `MEENSHA_HANDOFF_2026-08-16.md` as the living status
doc. That doc (and `MEENSHA_HANDOFF_2026-08-15.md`) still hold everything
from before this session; not repeated here.

## New this session: Instagram checkout-link mode

**What it is**: staff can generate a stand-alone Razorpay payment link for a
single inventory item — no existing customer or cart needed — for posting
straight into an Instagram post/story/bio-link. Built for the Shalini
(India) bot + `admin.html` only this pass; the Meenakshi/AU bot gets the
same feature duplicated over in a later pass once this one is proven out
(AU bot has no Razorpay/INR integration today — separate design needed).

**Where it lives**: inside the bot's existing "🔧 Maintenance" submenu, as a
new "🔗 Insta link" entry — the top-level bot menu stays at exactly 3
buttons (Kiosk mode / Enter inventory / Maintenance), per standing
constraint. Single item per link (matches how an Instagram post features
one product), reusing the same SKU/unit picker pattern Kiosk mode already
uses.

**Files changed**:
- `supabase/functions/telegram-bot/index.ts` — new `maint:iglink` menu entry
  and `iglink:*` handlers (`showIglinkItemPicker`, `showIglinkUnitPicker`,
  `showIglinkConfirm`, `sendIglinkPaymentLink`, `handleIglink`), reusing
  `create-payment-link` exactly like Kiosk's `sendRazorpayLink` does, tagged
  `source:"instagram"`.
- `supabase/functions/razorpay-webhook/index.ts` — the existing
  `source === "telegram_kiosk"` notify-back branch now also matches
  `source === "instagram"`, so the chat that generated the link gets told
  when it's actually paid.
- `admin.html` — Inventory tab gets a 🔗 button per in-stock SKU row
  (`genInstaLink()`), same `create-payment-link` call via the browser
  (anon key, same pattern the storefront cart already uses).
- No schema changes — reuses `orders` / `inventory_units` / `inventory_skus`
  as-is. Placeholder customer (`name: "Instagram Customer"`, dummy `wa`) is
  sent since there's no real buyer yet at link-generation time; Razorpay
  collects the real buyer's details at checkout.

**Status as of this note**:
- Both edge functions (`telegram-bot`, `razorpay-webhook`) are deployed
  live on the Supabase project — confirmed via `supabase functions deploy`.
- Code type-checked with `tsc` (no errors beyond expected Deno-global
  noise) — no live tap-through test was run against the real Shalini
  Telegram chat, to avoid sending her unsolicited real bot messages
  overnight. Needs a real walk-through (Maintenance → Insta link → pick
  item → pick unit → confirm → check the link) before trusting it fully.
- `admin.html`'s new button was written but not browser-tested this
  session (preview/browser tooling was unavailable in the autonomous
  window) — sanity-check the button + clipboard copy once live.
- Committed locally (`f240948`, meensha-test repo) — the 3 changed files
  only; 6 other pre-existing uncommitted files in that repo (index.html,
  telegram-bot-au, telegram-bot-monitor changes, plus some untracked files)
  are unrelated earlier in-progress work, left untouched.
- Not yet pushed to `origin` (production static site) or `test2` (staging)
  as of this note — only this docs update + the code commit are going to
  `gitea`. Pushing `origin`/`test2` will also carry along 7 other
  pre-existing local commits not covered by this session — worth a look
  before that push happens.

**Open follow-up**:
- Live tap-through test of the bot's Insta Link flow, real customer.
- Browser test of `admin.html`'s new 🔗 button.
- Decide when to push `test2`/`origin` (bundles unrelated pending commits).
- AU (Meenakshi) bot: duplicate the feature once the above is verified.
