# Meensha session handoff — 2026-10-28 — Stall readiness (QR, posters, prep checklist)

## Why this session happened

Diwali Santhe stall coming up. The ask spanned: a faster kiosk checkout for
walk-in sales (scan instead of tap through pickers), reusable event/promo
tooling (QR codes, posters, registration flows), a structured stall-prep
process so nothing gets missed, and a few real bugs found while testing
each piece live.

## What shipped (all live on meensha.in, all committed to `main`)

### Kiosk QR scan-to-cart
- Each unit's printed price tag now carries a QR encoding a proprietary
  `MSNU1:<unit_id>` token (deliberately not a real URL — scanning it with a
  random phone camera shows nothing clickable). kiosk.html gets a "📷 Scan"
  button that reads the tag via the camera (vendored `jsqr.js`, no CDN) and
  adds that exact physical piece straight to cart via the existing
  `reserve_unit()` RPC — no bypass of the double-sell guard.
- Found via review and fixed before shipping: leaving the scan screen by
  *any* path (not just cancel) now reliably turns the camera off — the
  original wiring only closed it on cancel/success/denial, so navigating
  away through the sidebar left it running in the background.
- Also compressed Stock Intake's invoice-photo capture (1600px/0.85 JPEG)
  before it hits Gemini OCR — modern phone cameras were sending
  full-resolution photos with no compression at all.

### Tag printing — real bug, found and fixed twice
- `printTags()` (admin.html) now embeds a QR per tag using the vendored
  `qrcode.js` library (extracted from admin-voucher.html into its own file
  so both pages can use it without duplicating ~2000 lines).
- First attempt generated the QR as a GIF data-URI — renders fine on
  screen, but Chrome's print-to-PDF pipeline silently drops GIF data-URIs.
  Switched to a canvas-drawn PNG instead.
- Second bug: the print sheet's CSS Grid layout (`display:grid`) doesn't
  reliably honor `page-break-inside:avoid` on its children in Chrome's
  print engine — a tag row could get sliced across a page boundary. Fixed
  by wrapping tag pairs in plain block-flow row containers instead.
- Both fixes were verified with actual headless-Chrome `--print-to-pdf`
  renders, not just browser screenshots, after the first "looks right in
  browser, blank in the real PDF" surprise. This is now the standing
  verification practice for anything print-related in this project.

### Events & Promotions — Instagram-follow gate, poster generator, A4 QR
- Optional per-event "require Instagram follow" toggle on registration
  (register.html) — honor-system only (no Instagram Business API access
  yet), captures the visitor's handle so staff can glance at it and
  confirm at redemption rather than a hard technical gate.
- Real bug fixed: `admin-voucher.html`'s login check still read an old
  `sessionStorage.MSN_USER` key that nothing had written since admin.html's
  login moved to `localStorage.MSN_ADMIN_SESSION` months ago — every
  admin.html → admin-voucher.html handoff (coupon vouchers *and* the new
  event QR) was silently showing "Not logged in."
- A real poster generator (`generateEventPoster()`) — events can link to an
  existing Pop-Up Event; its first uploaded photo becomes the poster
  background (title + discount + a scannable registration QR), replacing a
  stub that had been waiting on static template PNGs nobody ever supplied.
- A plain, large "Print A4" QR (no poster art, no discount text) for
  sticking onto an existing physical banner/standee — also went through a
  real bug: the first version used `height:100vh` with flexbox centering
  for the print page, which Chrome's print engine renders as effectively
  zero height, so the whole page came out blank. Fixed with plain block
  layout, verified via headless-Chrome PDF.

### Printable A4 stock sheet
- New "🧾 Stock Sheet (A4)" button in Inventory — landscape A4, one page,
  SKU Code/Name/Material/Variant/Available/MRP/Disc%/Discount Price (the
  last two straight from `inventory_skus.disc`/`.sale_price`, no new
  computation) plus blank "Sales" tally columns for hand-marking each sale
  during the stall. Verified at both 20 and 40 rows via headless-Chrome PDF
  to confirm single-page fit.

### Stall-prep checklist (the big one)
- Every Pop-Up Event now auto-gets a 4-phase prep checklist the moment
  it's saved — Book Stall → Publicity → Inventory check → Final
  coordination — created from either admin.html or a new kiosk-side event
  creation screen (same fields as admin's form).
- The checklist is a proper **editable template**, not a fixed list: admin
  or kiosk can add/remove/rename/reorder phases and items (drag-and-drop in
  admin.html; up/down buttons in kiosk.html, since native HTML5
  drag-and-drop isn't reliable on touch WebViews). Each event's checklist
  is a snapshot copied from the template at creation time — editing the
  template afterward never retroactively changes an already-created
  event's checklist.
- Kiosk gets a pulsing red "urgent" banner pinned to the top, visible
  whenever any item across any upcoming/live event's checklist is still
  unchecked, disappearing the instant the last one is ticked — checkable
  from kiosk directly, not just admin.html, so staff don't need to switch
  apps.
- Post-event notes: a kiosk notepad icon for free-text learnings, saved
  and attributed per event. Admin triggers "Analyze & Submit" to summarize
  via the existing OpenRouter→Gemini fallback and relay to both Telegram
  and a new admin.html section — kiosk only writes notes, never triggers
  analysis itself.
- Built via a full supervisor → builder → checker → security-audit → QA
  pipeline. The security pass caught a real HIGH-severity stored-XSS gap
  (an unescaped event title, reachable via the kiosk-side creation path)
  plus two medium bugs (a summary-lookup NULL-handling bug, missing
  validation on kiosk-submitted event data) — all fixed and independently
  re-verified before shipping.

### Kiosk event-offer toggle + unprefixed codes (parallel session, same day)
- Per-event on/off switch for whether its discount shows in kiosk's
  discount picker — default on, so nothing changes for an event until
  someone flips it off.
- Newly minted event-registration codes drop the `MSH-` prefix to match
  manually created voucher codes (e.g. `DIWALI200`) — one scan/type
  pattern for every code type going forward. Already-issued `MSH-` codes
  remain valid.

## Real bugs found and fixed along the way

- GIF-vs-PNG data-URI print bug (tag QR codes) — see above.
- CSS Grid page-break bug (tag printing) — see above.
- `height:100vh` print-blank-page bug (A4 QR) — see above.
- `admin-voucher.html` stale session-storage key blocking every
  admin.html handoff — see above.
- A HIGH-severity stored-XSS gap in the new notes section, caught by the
  security-audit stage before shipping.
- A pre-existing, unrelated bug noted but *not* fixed (out of scope,
  surgical-change discipline): admin.html's older Pop-Up Events list
  (`EV-LIST`) renders `ev.title` unescaped — predates this session's work,
  flagged for a future pass.

## Process notes

- Established practice this session: any print/PDF output claim must be
  verified with an actual headless-Chrome `--print-to-pdf` render of the
  real generated HTML, not just a browser screenshot — this project was
  burned twice by print features that looked correct on screen and
  rendered blank/broken in the real PDF.
- The two large builds (QR scan-to-cart, stall-prep checklist) each used a
  supervisor-orchestrated pipeline (builder → checker → security audit →
  QA → consolidated report), with the coordinator doing its own
  independent verification of every claim before reporting it as done —
  caught real issues each time, including a HIGH-severity XSS gap.
- All schema migrations and Edge Function deploys in this session were
  written by the assistant but **applied/deployed by the project owner
  directly** (`supabase db push` / `supabase functions deploy`) — an
  auto-mode safety gate blocks AI-triggered production database/deploy
  actions in this environment, by design. Exception in the follow-up round:
  migration `20261028200000` was applied to production by the assistant on the
  owner's explicit instruction, after a `supabase db push --dry-run` confirmed
  it was the only pending migration.
- A second, parallel session ("Meensha stall kiosk issues") worked
  concurrently on a separate set of kiosk fixes (Razorpay link, visiting-card
  auto-WhatsApp-send on 10-digit entry, the offer-toggle/unprefixed-codes
  work folded into this handoff) — both sessions' work was committed
  together in one push once confirmed to be the same person's work.

## Follow-up round — kiosk payments, card share, codes, Instagram gate

Second session, same day. Everything below is committed to `main` and
pushed to `origin` (`0a59711`, `b63654d`, `a2c822e`, `a081d87`, plus the kiosk/Razorpay/card-share
work already in `e0b7fc4`). Live status: pushed, so meensha.in serves it once
GitHub Pages redeploys. Not browser-tested end to end and not live-tested
against Razorpay — verify before relying on it at the stall.

### Kiosk fixes
- **Razorpay link "doesn't work" — root cause found.** The kiosk sent the
  `Prefer` header (via `HDR()`) to Edge Functions. `create-payment-link`
  CORS allows only `authorization`, `apikey`, `content-type`, so the browser
  rejected the preflight before the function ran, and the kiosk always showed
  "Couldn't create the Razorpay link". Fixed with a `FN_HDR()` helper used for
  `create-payment-link` and both `generate-invoice-pdf` calls.
- **Custom ₹/A$ discount + Razorpay blocked.** `create-payment-link` only
  knows coupon discounts, so a custom discount would be quoted but charged at
  full price. The kiosk now refuses Razorpay in that case and points to
  Cash/UPI/Other.
- **Visiting-card share auto-sends.** The 10th digit (with a name entered)
  saves the potential customer and opens `wa.me/91<number>`, once per number.
  The old link had no `91`, so it went to the wrong chat.
- **Event offer hidden per customer.** If the customer already holds a coupon
  for an event, that event's generic button is hidden; they enter their own
  code instead.
- **Event offer on/off.** Kiosk "Create event or promotion" lists running
  events with On/Off. Admin.html's Events & Promotions table has a matching
  "Kiosk offer" checkbox column. Both use `admin_set_voucher_event_kiosk_offer`
  (session-guarded). Migration `20261027250000_kiosk_offer_toggle.sql`
  (applied).
- **Code entry.** Plain code box, no `MSH-` prefix. A "📷 Scan customer's QR"
  button opens the existing jsQR scanner in voucher mode: it ignores anything
  that isn't a voucher code (unit tags included), keeps scanning, and applies
  the scanned code as if typed. Unit-tag scanning on the Items screen is
  unchanged.
- **Discount-code display.** Event registration codes are 6 characters with no
  prefix (`supabase/migrations/20261028100000_voucher_codes_no_prefix.sql`).
  Existing `MSH-` codes do not exist, so nothing needed migrating.

### Register page (`register.html`)
- **Customer QR download.** The code screen shows a QR rendered locally from
  the vendored `qrcode.js` (no CDN) and a "⬇️ Save QR image" PNG button.
- **Instagram follow gate (events with "require Instagram").** A full-page
  Follow screen first, with an "I've followed — continue" button (no
  countdown). Then a dialog asking only for the `@handle`, then "Thanks!".
- **Logo.** The header and follow screen use the animated coin logo
  (`meensha_rotating_logo.webp`, the same one the main site uses). The
  Hindi logo was rejected.
- **WhatsApp field.** Exactly 10 digits, with +91 fixed in the UI. Sent to
  the backend as 10 digits, matching how other customer numbers are stored.
- **No email.** The page no longer asks for one. Migration
  `20261028300000_event_register_optional_email.sql` makes email optional in
  `register_event_visitor`; a customer row is created only when an email is
  given. **Applied to production on 2026-10-28** after a dry run confirmed it
  was the only pending migration. Committed and pushed as `a081d87`.

### Kiosk staff alert for Instagram handles
- After login, the kiosk checks every 60 seconds for event registrations in
  the last 24 hours that captured a handle. Each new one toasts "🔔 @handle
  generated code X (event) — check they follow on Instagram". Seen codes are
  stored per device in localStorage; the first run seeds silently.
- Toasts show for about 2.6 seconds, so several at once may show only the
  last one.
- Backed by migration `20261028200000_ig_registration_alerts.sql`
  (`admin_recent_ig_registrations`, session-guarded). **Applied to production
  on 2026-10-28** with `supabase db push`, after a dry run confirmed it was the
  only pending migration. An anonymous probe returned 403 as expected.

### Still open
- **Live test on the stall-day devices:** Razorpay link creation, the
  card-share popup on a phone, the QR download, and the Instagram alert with a
  real admin login.
- **Custom-discount + Razorpay:** blocked, not solved. A real fix needs the
  edge function to accept the custom discount, with server-side validation.
- **Telegram bot prompt** still shows "e.g. MSH-A3F92" (text only, needs an
  edge-function redeploy to change).
- **No raw-notes viewer** in admin.html before "Analyze & Submit" — QA flagged
  as nice-to-have, not built.

### Supervised audit round (2026-10-28, ~02:40 IST)
A supervisor run delegated a QA agent and a security agent (both read-only,
all network stubbed, nothing submitted to production), then triaged.

- **Live break found and fixed (HIGH).** Commit `a081d87` made
  `register.html` stop sending `p_email`, but `register_event_visitor`'s
  signature still has `p_email` without a default, so PostgREST returned
  404/PGRST202 and **every event registration failed** from that push until
  `e3a748a`. Confirmed with a harmless probe (zero-UUID event, no writes).
  Fixed client-side by sending `p_email: ''` (the function accepts blank).
  Lesson: after changing an RPC's inputs, probe it with the page's exact body.
- **Fixed in `e3a748a`:** `register.html` QR now comes from the vendored
  `qrcode.js` (no CDN, no integrity-hash gap) and is exported as a real PNG
  (the library's own data URL is a GIF); `admin.html` `EV-LIST` and
  `renderRevs` now escape customer/staff text (the reviews list was a stored
  XSS into the admin session).
- **QA results (all PASS):** handle validation, 10-digit WhatsApp (9/11 digits
  and letters rejected, spaces stripped, body has no email), QR decodes to the
  code with a PNG download link, no console errors or local 404s on register
  and kiosk, no horizontal scroll at 375px. Notes: `@@x` is accepted and stored
  as `@x` (intended); admin.html logged one "failed to fetch script" console
  error, most likely the xlsx CDN (not investigated).
- **Hardening migration — APPLIED to production 2026-10-28** (after a dry run
  confirmed it was the only pending migration):
  `20261028400000_register_event_visitor_hardening.sql` gives `p_email` a
  default, stops the anon path from UPDATEing existing unverified customer rows
  (account-overwrite risk), caps name/WhatsApp lengths, and validates and
  normalizes the Instagram handle server-side. Post-apply probes (zero-UUID
  event, no writes) resolved with HTTP 200 both with and without `p_email`. The
  server-side validations themselves have not been exercised end to end; do one
  real registration on a test event to confirm.
- **Audit findings left open (decisions for the owner):**
  - MEDIUM: no rate limit on minting codes (the event link is public).
  - LOW: `register_event_visitor` returns an existing code to anyone who types
    that WhatsApp number (front-running risk; mitigation is to return only
    "already registered" and let staff look it up).
  - MEDIUM: `admin_list_voucher_events()` is anon-readable (event names,
    registrant counts) — needs a session guard, but check storefront callers
    first.
  - LOW: kiosk `esc()` does not escape `'` and a few `onclick` handlers embed
    staff-entered titles; changing `esc` globally would break those handlers, so
    pass ids instead.
  - Instagram follow is honor-system only (staff check on the kiosk alert).

### Owner decisions on those findings (2026-10-28) and the permanent QR
- **Rate limit:** cap of 20 new codes per minute per event.
- **Code leak:** keep returning an existing code for an already-registered
  number (codes are number-bound and redeemed in person).
- **Event list guard:** guard `admin_list_voucher_events()` with
  `require_admin_session()` after checking callers. Checked: admin.html and
  both kiosk.html calls all send the admin session; no anonymous caller.
- **Permanent QR:** printed/poster/A4 QRs now encode
  `https://meensha.in/register.html?event=current`. `register.html` resolves
  that through `get_current_voucher_event()` to the **newest active**
  event/promo; deactivate the old one in admin and the same QR moves on. If
  nothing is active the page says "No offer is running right now". Changed in
  `admin.html` (`openEventQR`, `generateEventPoster`, `CURRENT_EVENT_LINK`) and
  the QR image in kiosk.html's Create event result. The clickable per-event link
  text (and the Telegram bots' links) is unchanged and still event-specific.
- **All of the above ships in migration
  `20261028500000_current_event_ratelimit_listguard.sql` — APPLIED to
  production 2026-10-28.** Verified with anonymous probes (no writes):
  `get_current_voucher_event` returns "Diwali Santhe 2026" (newest active,
  Instagram required); `admin_list_voucher_events` without a session returns
  403 `admin_session_invalid`; `register_event_visitor` with a blank email
  resolves. The code (`e50ad9a`) reached origin via the parallel session's
  push (`3c15069`); the live register page already serves `?event=current`.
- **NEW finding, fix prepared but NOT applied:** the original 3-argument
  `register_event_visitor(uuid, text, text)` (from
  `setup/add_voucher_events.sql`) was never dropped and is still anon-callable.
  It bypasses the rate limit, the server-side Instagram requirement/validation
  and the length caps, so anyone calling it directly can skip the follow gate
  and the 20/minute cap. It also makes a 3-field RPC body ambiguous (PGRST203).
  Only `register.html` calls this RPC (always the 5-arg form), so dropping it
  is safe. Migration `20261028600000_drop_legacy_register_event_visitor.sql`
  does exactly that — apply with `supabase db push`.
