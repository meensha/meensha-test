# Kiosk Sale Flow (Telegram Bots)

Both regional bots have a "Kiosk mode" — the flow staff use to record a sale on the spot
(at a pop-up stall, or any in-person transaction) without opening a laptop.

```mermaid
sequenceDiagram
    participant Staff
    participant Bot as Telegram Bot (India or AU)
    participant DB as Supabase

    Staff->>Bot: taps "Kiosk mode"
    Bot->>DB: load available SKUs for this bot's region
    Bot->>Staff: shows item picker (name + available count)
    Staff->>Bot: picks item(s), adds to cart
    Bot->>Staff: shows running cart (add more / remove / checkout)
    Staff->>Bot: enters customer WhatsApp number, then name
    opt coupon applied
        Staff->>Bot: types a coupon code (or it's pre-seeded from a deep link)
        Bot->>DB: validate coupon
        DB-->>Bot: discount applied, or rejection reason
    end
    Staff->>Bot: picks payment mode (Cash / UPI / Razorpay / Other)
    alt Razorpay
        Bot->>DB: create a real Payment Link (same function the storefront cart uses)
        Bot->>Staff: sends the link to forward to the customer
        Note over DB: sale is only recorded once Razorpay's webhook confirms payment — see checkout-payment-flow.md
    else Cash / UPI / Other
        Bot->>DB: records the sale immediately, claims the chosen unit(s) as sold
        Bot->>Staff: sends an invoice-style summary + WhatsApp deep link to forward to the customer
    end
    Bot->>DB: best-effort notify MeenshaMonitor
```

## Key details

- **Persistent, not one-shot**: after a sale, Kiosk mode loops back to the item picker
  instead of resetting to the idle menu — built this way because staff typically ring up
  several sales back-to-back.
- **Stock check happens live**: picking an item shows its real current available count, and
  the bot won't let a sale proceed past what's actually in stock.
- **The unit, not just the SKU, gets claimed**: a sale picks (or the system assigns) a
  specific physical unit, which is what actually gets marked `sold` — this is what prevents
  two staff members, or a staff member and the storefront, from selling the same physical
  piece twice.
- **Cash/UPI/Other sales write to `sales` immediately.** Razorpay-mode kiosk sales do
  **not** — the bot only generates and sends a payment link; the sale itself isn't recorded
  until Razorpay confirms the payment (see `checkout-payment-flow.md`). This matters if
  you're reconciling "why isn't this sale showing yet" — an unpaid Razorpay link from the
  kiosk simply hasn't resulted in a sale yet.
- **Invoice delivery**: for non-Razorpay sales, the bot builds the invoice text itself and
  hands staff a ready-to-send WhatsApp link; for Razorpay sales, the real branded PDF
  invoice (see `invoice-generation.md`) is what eventually reaches the customer once payment
  lands.
- **Region scoping**: the India bot only shows India-available stock/pricing; the Australia
  bot only shows Australia-available stock/pricing (in AUD). Each SKU carries its own
  per-region availability flag.
