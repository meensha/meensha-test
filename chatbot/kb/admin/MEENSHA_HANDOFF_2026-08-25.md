# Meensha Handoff — 2026-08-25

## New this session

- **Kiosk mode rewritten**: persistent (loops back to item picker instead of resetting to idle after each sale), quantity-based stock check ("Only X available"), explicit Cart screen (add/remove/checkout), WhatsApp captured before name (auto `+91`, 10-digit validated), coupon applied at order summary. Razorpay sales now go through the real `create-payment-link` function (same as the storefront) and only get written to `sales` once `razorpay-webhook` confirms payment — the webhook now also messages the originating Telegram chat once paid.
- **Events**: real `date_from`/`date_to` columns + validation (no past start date on new events, end ≥ start) in admin.html's event form.
- **Sales History (bot)**: new "🧾 Sales history" menu — last-5 paginated browsing, tap a sale for summary + resend invoice.
- **Invoice deep link**: `admin.html?invoice=<inv>` auto-opens the real branded invoice — the bot links here instead of building its own text invoice.
- **Signup form** (storefront + new event-photos page): country-code picker (default 🇮🇳 +91, 12 countries) next to the mobile number field, combined into the canonical digits-only `wa` format on submit.
- **Public event-photo submission** (`event-photos.html`, new page): gated by an explicit Telegram-toggleable `settings.event_photo_submission_enabled` flag (wins outright when set), falling back to the event's own date range when untouched. Requires the real customer login/signup (not a lightweight capture). Captures a per-photo caption + one optional Instagram @handle per submission.

## Still pending / blocked

- **Instagram auto-posting is wired but inert** — `event-photo-submit` Edge Function batches every 4 unposted photos into an Instagram carousel post (container → carousel container → publish), captioned `"From {Event} — photos by @handle1, name2, ..."` (handle if given, else the submitter's name). It silently no-ops until these two secrets are set:
  ```
  supabase secrets set INSTAGRAM_ACCESS_TOKEN=... INSTAGRAM_BUSINESS_ACCOUNT_ID=...
  ```
  Getting there requires, outside of code: an Instagram Business/Creator account linked to a Facebook Page, a Meta Developer App, and a long-lived access token with `instagram_content_publish` permission. None of that can be done from this session — it's an external account/consent flow, same shape as the Resend blocker below.
- **Resend sender domain still not verified** (carried over from 08-15/16, re-confirmed 2026-08-25 via `supabase secrets list` — no `EMAIL_FROM` secret set) — real customer signup OTP emails still only reach the Resend account owner's own registered email address, not actual customers. This blocks the *real* login/signup path that event-photo submission now depends on, so public photo submission is functionally dark until this is fixed, even though it's fully built.

## Reference

- New migrations this session: `setup/add_orders_telegram_source.sql`, `setup/add_events_date_range.sql`, `setup/add_event_photo_submission.sql` — all need to be run in the Supabase SQL Editor before/alongside the matching Edge Function deploys.
- New Edge Function: `event-photo-submit` (verify_jwt: true — called with the anon key like `create-payment-link`, not a webhook).
