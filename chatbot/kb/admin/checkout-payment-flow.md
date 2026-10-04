# Checkout / Payment Flow

Two genuinely different checkout paths exist, split by market — there is no online payment
integration for Australia today.

## India — Razorpay (when enabled) or WhatsApp fallback

```mermaid
sequenceDiagram
    participant C as Customer
    participant Site as index.html (or Telegram kiosk)
    participant Fn as create-payment-link (Edge Function)
    participant RZP as Razorpay
    participant Hook as razorpay-webhook (Edge Function)
    participant DB as Supabase

    C->>Site: checks out (Razorpay toggle is ON)
    Site->>Fn: request a payment link for this cart's exact total
    Fn->>RZP: create a dynamic Payment Link
    Fn->>DB: create a pending "order" row (items, total, reserved unit ids, coupon if any)
    Fn-->>Site: payment link URL
    Site->>C: redirect / hand off to Razorpay's hosted checkout
    C->>RZP: pays (UPI / card / netbanking)
    RZP->>Hook: payment_link.paid webhook
    Hook->>Hook: verify the webhook's signature
    Hook->>DB: mark the order paid, claim the reserved unit(s) as sold
    Hook->>DB: insert the matching "sales" row (so it shows up exactly like a manual sale)
    Hook->>DB: consume the coupon, if one was attached
    Hook-)DB: kick off invoice PDF generation (best-effort, doesn't block the webhook response)
    opt sale originated from a Telegram kiosk link
        Hook->>C: (via the bot) tell staff "payment received, hand over the item"
    end
```

If the Razorpay toggle is **off**, or a customer is browsing the India storefront without
completing online payment, checkout instead builds a pre-filled WhatsApp message (items,
prices, customer info) and hands off to WhatsApp — the owner then confirms/arranges payment
manually.

## Australia — WhatsApp only, always

Australia has no payment gateway integration. Every Australian checkout — storefront or
kiosk — ends the same way: a pre-filled WhatsApp enquiry message to the Australia WhatsApp
number, with Meenakshi handling payment and fulfillment manually from there.

## Why the webhook matters

The webhook (`razorpay-webhook`) is the **only** place that actually knows a payment
landed — a kiosk-generated Razorpay link doesn't finalize anything in the bot itself; staff
just send the link and move on. Until the webhook fires, the order sits in a pending state
and no `sales` row exists yet. The webhook is idempotent by design (Razorpay can and does
retry webhook delivery) — it checks whether the order is already marked paid before doing
anything, so a duplicate delivery doesn't double-record a sale.

## Price integrity

The price a customer actually pays is always the server-side total computed at payment-link
creation time, not anything editable in the browser — the Edge Function builds the Razorpay
request with its own computed total, not a number trusted from the client.
