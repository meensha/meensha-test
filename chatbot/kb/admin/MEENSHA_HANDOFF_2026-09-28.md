# Meensha — Handoff / Current State (2026-09-28)

Session note. It supersedes `MEENSHA_HANDOFF_2026-09-27.md` as the living
status doc. Everything in that doc still holds unless it's corrected here.
`meensha-test/TODO.md` is still the day-to-day tracker. All three remotes
(origin, test2, gitea) are at `40b8dcf`.

## New this session

**Database locked to admin sessions (security fix, finished).** The last
session left this half done: commit `3608a56` was pushed, the page changes
were uncommitted, and the lock migration was parked in `.pending-lock/`.
Before the lock, the public anon key embedded in every page could read and
write `users` (5 rows), `sales` (31, with customer details), `purchases`,
`vendors`, `overheads`, `sku_vendor_batches`, `vendor_audit_log`, and
`inventory_skus.cost`.

Shipped in order, each step verified before the next:
1. `20260927190000_public_views_and_rpcs.sql` (Dheeraj ran it in the SQL
   editor). It adds the `public_skus` / `public_units` views (no cost or
   vendor columns), `get_invoice(inv, wa)` (the WhatsApp match now happens
   server-side), `staff_forgot_password()`, and `has_admin_session()`. It
   makes `reserve_unit` / `unreserve_unit` / `release_expired_reservations`
   SECURITY DEFINER, and narrows the safe-settings policy to 8 keys.
2. Page changes, commit `531bd5e`. index.html, product.html and
   sarees/weave.js read the public views. invoice.html uses `get_invoice`.
   admin.html sends `x-admin-session` on every table call and RPC, and it
   checks `has_admin_session()` at start and every 5 minutes, sending the
   user back to login when the session has expired.
3. `20260927191000_lock_tables_to_admin_session.sql` (Dheeraj ran it). It
   drops the allow-all anon/authenticated policies on 23 tables and
   replaces them with `has_admin_session()`.

After the lock, anon can read only `instagram_posts`, `popups`, 6
`settings` rows, approved `reviews` (0 right now), and the two public
views. I checked this per table with row counts only, never row data. The
edge functions and bots all use the service-role key, so the lock doesn't
affect them (I checked all 22). Dheeraj confirmed that admin.html logs in
and every tab loads after the lock.

**Full QA, automated (Playwright), on staging and meensha.in, desktop
1366px and mobile 360px, before and after the lock.** Pages: home, the
`?shop=` search, `/sarees/`, 2 weave pages, product, about, register,
event-photos, invoice (wrong WhatsApp gives "not found"), and the admin
login screen. The customer journey: `?buy=` adds to the cart (unit
reserved), the cart renders, a fake coupon gets "Code not found.", a fake
customer login is rejected, and "Pay via Razorpay" reaches the contact
form. I stopped there on purpose, so no payment link or order was created.
Removing the item puts the unit back to available. Every run had no
console errors, no failed Supabase calls and no horizontal overflow.

**Two mobile cart bugs fixed (commit `61a4da4`).** Both were pre-existing
and found by the QA.
- The 10s "Handpicked. Not Held Forever" nudge covered the cart items on
  mobile, because adding an item always opens the drawer. The nudge's 10s
  window now starts only once the drawer is closed. The final-30s
  persistent warning is unchanged.
- The coupon row overflowed the drawer at 360px. Below 640px it now
  wraps: code + Apply on one line, the WhatsApp field full width under
  them. The desktop layout is unchanged.
Verified at 360, 390 and 1366, locally, then on staging, then live.

**Merged a cloud-routine commit.** `d3c8c82` adds `page_views` logging on
`/sarees/*` and product.html. It had landed on test2 in the meantime. It
has no overlap with the lock work, and `page_views` inserts stay public.

**Credentials moved to the Keychain.** The GitHub PAT was replaced; the old
one was deleted on GitHub. It had also shown up in this session's tool
output once, before being revoked. All git credentials for `meensha-test`
now live in the macOS Keychain (`credential-osxkeychain`), and
`.git/config` has no secrets left. Remotes:
- `origin` is `https://github.com/meensha/meensha-test.git`
- `test2` is `https://github.com/meensha/meensha-test2.git`
- `gitea` is the self-hosted backup mirror, reachable only from the local
  network (not a public internet address)

A scan of the other repos on this Mac found no other embedded GitHub
tokens.

## Known gaps / open items

- **Oct 1:** the GSC reminder routine (`trig_01Dkj5283pX36qSL7Z8StgiY`)
  fires to check whether the category-page indexing fix moved the
  counts. Measurement dates for the SEO audit are Oct 4, 11 and 25 (see
  `meensha.in-audit/MEASUREMENT.md`).
- Still open from the 09-27 audit, waiting on the owners or Dheeraj: font
  trimming (needs the owners' OK), Merchant Center, the 43 empty
  `inventory_skus.description` values, `popups.date_from`, the SKU name
  typos, and the two keyword calls (Chenon/Chennon, Jaipur/Surat).
- Tables not in the lock list were probed, and anon sees 0 rows in them
  (customers, coupons, sessions, telegram tables and so on). Anything
  added to the schema later needs its own RLS policy. It won't inherit
  the lock.
- The QA scripts are saved in `meensha-test/setup/qa/` (`qa.py` for the
  full page and customer-flow QA, `cartfix.py` for the mobile cart,
  `probe.py` for the anon table-exposure check). How to run them is in
  that folder's README. Re-run `probe.py` after any schema change.
- Everything in the 09-27 and 09-13 "Known gaps" lists not covered above
  still applies.

## Working conventions (still apply, plus two from this session)

- Staging and production share **one Supabase project**
  (`eglanmhhcccsuhbxywua`). A migration goes live on both sites the
  moment it runs, so "test on staging first" only isolates page changes.
  Order the rollout so pages never depend on SQL that hasn't run yet.
- To push to gitea from a sandboxed session that can't resolve the local
  hostname, the LAN IP can be supplied directly via a git curl-resolve
  override (see ops notes for the exact address).
- Still true: fetch and diff before every push (the cloud routine pushes
  to test2 on its own schedule), migrations are run by Dheeraj in the
  Supabase SQL editor (hand them over with `pbcopy`), and run a QA pass
  before shipping anything that touches live data.
