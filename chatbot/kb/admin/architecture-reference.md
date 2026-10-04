# Architecture & Schema Reference

A from-scratch summary of Meensha's data model and core architecture, written for this
knowledge base. It carries forward the *structural* knowledge from the project's earliest
planning document, but nothing has been copied verbatim from it — in particular, that
original document contains plaintext staff passwords, so it was deliberately never copied
into this knowledge base. If you need the original for historical reasons, it's in
`docs/Project Brief v3.md` in the main repo (outside this chatbot's knowledge base).

## About the business

Meensha (मीनशा) is a heritage Indian handloom saree brand, owned by Shalini and Meenakshi.
It sells through WhatsApp, pop-up exhibitions, and its own e-commerce storefront, across
two markets: India (INR, primary) and Australia (AUD, secondary).

## Tech stack, at a glance

- **Frontend**: two static HTML files (`index.html` the storefront, `admin.html` the admin
  panel), plus a handful of smaller standalone pages (`admin-voucher.html`, `product.html`,
  `invoice.html`, `register.html`, `event-photos.html`). Hosted free on GitHub Pages.
- **Backend**: a single Supabase project — Postgres database, Row-Level Security, Storage
  (for photos), and Edge Functions (serverless TypeScript, Deno runtime).
- **AI**: Claude (Anthropic) for invoice/receipt scanning and product-photo descriptions;
  Gemini for natural-language Q&A in the Telegram bots and AI price benchmarking.
- **Payments**: Razorpay for India (real dynamic Payment Links), WhatsApp order/enquiry as
  the fallback everywhere else (always, for Australia).
- **Staff tooling**: two region-specific Telegram bots (India/Shalini, Australia/Meenakshi)
  plus a separate owner-facing monitoring bot.
- **No paid infrastructure** — every service used has a free tier the business stays within.

## Why the architecture looks the way it does

The Supabase anon key is hardcoded into the public HTML pages. That's deliberate, not an
oversight — Supabase's own design intends the anon key to be public, with Row-Level Security
policies (database-side rules about who can read/write which rows) doing the actual access
control. Anything more sensitive — AI/payment provider keys, the service-role key used by
Edge Functions — never lives in client code; it's either in the `settings`/`app_secrets`
tables (readable only by an authenticated admin session) or in Supabase's own server-side
secrets store (readable only by Edge Functions, never the browser).

## Core data model

The foundational design decision in this schema: a saree is not a fungible unit. Two pieces
of the "same" SKU are still two distinct physical objects, so the schema separates:

- **`inventory_skus`** — one row per *product type* (a weave/material/variant combination):
  name, material, cost, MRP, sale price in INR and AUD, a running batch counter, and a
  generated storefront description.
- **`inventory_units`** — one row per *physical piece*: which SKU it belongs to, which
  purchase/batch it came from, its own photo, and a status (`available` / `sold` /
  `reserved` / `damaged` / `returned_to_vendor`).

Everything downstream — stock display, cart reservations, sales, vendor returns — is built
on this split, because "10 in stock" is a genuinely different claim from "these 10 specific
pieces exist."

Other core tables:
- **`purchases`** — one row per supplier purchase (invoice, items, totals, partner payment
  split).
- **`overheads`** — day-to-day business expenses, multi-tagged, split between the two
  owners.
- **`sales`** — one row per completed sale, however it was made (admin manual entry, either
  Telegram bot's kiosk mode, or an online Razorpay-paid order), with a `source` field
  recording which.
- **`settings`** — a key/value table for anything that should be configurable without a code
  change (WhatsApp numbers, currency multiplier, feature toggles, counters).
- **`coupons`** — discount codes, either locked to one customer's WhatsApp number or public,
  with region and single-use/reusable behaviour (see the coupon/voucher flow doc for detail).

## Atomic / safety-critical database functions

A few operations are deliberately implemented as single atomic database functions rather
than multi-step client code, specifically to avoid race conditions:
- Claiming a unit as sold (so two staff members, or a staff member and the storefront,
  can't both sell the same physical piece).
- Placing and releasing a cart reservation hold (a short-lived "this piece is spoken for"
  lock while a customer is mid-checkout).

## Roles

Three roles exist in the live `users` table: `super_admin` (Dheeraj), `owner` (Shalini and
Meenakshi), and `sales` (kiosk/point-of-sale staff, region-scoped to India or Australia).
Each role sees a different, configurable subset of the admin panel's tabs — see
`ARCHITECTURE.md` and the admin role-gating flow doc in this knowledge base for how that's
enforced today.

## Markets

India and Australia are the only two markets. The storefront auto-detects the visitor's
likely market from their IP location and defaults the currency/WhatsApp-number accordingly,
with a manual toggle available. India can check out online via Razorpay (when enabled) or
fall back to a WhatsApp order; Australia always goes through a WhatsApp enquiry, since there
is no local online payment integration today.
