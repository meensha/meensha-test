# Coupon / Voucher Lifecycle

Covers the full life of a coupon code: creation, how it's handed to a customer (QR code or
Telegram deep link), redemption at checkout, and retirement.

## Creating a coupon

A coupon is created either from `admin.html`'s Coupons tab or from either Telegram bot's
voucher menu (both call the same underlying database function). Every coupon has:

- A **code** (stored uppercased/trimmed).
- An optional **customer lock** — a name + WhatsApp number. If set, only that WhatsApp
  number can redeem it. If left blank, the code is **public** — anyone who types it can use
  it.
- A **region** — India only, Australia only, or both.
- A **discount** — percent off or a flat amount, optionally restricted to items matching a
  category filter (e.g. only dupattas).
- A validity window (`valid_from` / `valid_until`).
- A **single-use flag**. This only matters for *public* codes: a locked code is always used
  up on its first (and only valid) redemption regardless of this flag. A public code with
  the flag off stays reusable by anyone, forever, within its date range (this is how
  storefront-wide promo codes work) — with the flag on, it's consumed the first time anyone
  redeems it, then dead for everyone after.

## Getting the code to a customer

Two distinct generation paths exist, producing different artifacts from the same
underlying coupon:

1. **Voucher image** (`admin-voucher.html`) — a printable/shareable canvas-rendered image
   (three styles: Partner Offer, Event Offer, Individual Discount) with a scannable QR code
   baked in. The QR can encode either:
   - A **website link** (`meensha.in/?coupon=<code>`) — opens the storefront with the code
     pre-filled, or
   - A **Telegram deep link** (`t.me/<bot>?start=coupon_<code>`) — opens the relevant
     region's bot straight into Kiosk mode with the code already seeded, for an in-person
     sale.
2. **Event registration** (`register.html?event=<id>`) — a different path, for handing out
   *individual* one-time codes to multiple people (e.g. everyone who visits a pop-up stall):
   each visitor who submits their name + WhatsApp number gets their own freshly-minted,
   locked, single-person coupon.

## Redemption — storefront

```mermaid
sequenceDiagram
    participant C as Customer
    participant Site as index.html
    participant DB as Supabase (validate_coupon / consume_coupon)

    C->>Site: enters code (or arrives via ?coupon=<code> link)
    Site->>DB: validate_coupon(code, wa, region)
    DB-->>Site: valid / invalid + reason (not found, wrong region, expired, already used, WA mismatch)
    Site->>C: shows discount applied, or the specific rejection reason
    C->>Site: proceeds to checkout (Razorpay or WhatsApp)
    Site->>DB: consume_coupon(code, wa) — on confirmed order
    DB-->>Site: locked code marked used; public code only flips to used if single_use
```

## Redemption — kiosk (Telegram bots)

Both bots' Kiosk mode has a coupon-entry step during checkout. There's a real asymmetry
between the two bots worth knowing:

- **Australia bot** calls the same shared `validate_coupon` database function the
  storefront uses, so it gets the same region-specific rejection messages (e.g. "This code
  is India only.").
- **India bot** validates coupons with its own local check directly against the coupons
  table, with a more generic message. This is a pre-existing inconsistency, not a recent
  change — both work, but the India bot's user-facing error text is less specific.

A coupon can also arrive **pre-seeded**: tapping a `t.me/<bot>?start=coupon_<code>` deep
link launches Kiosk mode with the code already attached to the session, so the existing
coupon-entry step auto-validates it instead of prompting staff to type it in again.

## Retirement

- A **locked** coupon is marked used the moment it's successfully redeemed once — no manual
  step needed.
- A **public, single-use** coupon is marked used on its first successful redemption, the
  same way.
- A **public, reusable** coupon (the default) is never auto-marked used — it stays valid
  until its `valid_until` date passes, or until a super_admin/owner manually deactivates it
  from the Coupons tab.
