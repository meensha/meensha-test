# System Map — Index

This is the admin-tier index of "how things actually work" flow docs, written directly from
the current codebase (not just from historical handoff notes, which don't uniformly cover
everything end-to-end). Start with `ARCHITECTURE.md` for the one-page shape of the whole
system, then open whichever flow doc below answers your question.

Per `CURATION_NOTES.md`, every doc here explains flows at the "what happens, in what order,
what talks to what" level — never the literal security-mechanism code (password/token
hashing, RLS policy text, webhook-secret comparisons). That boundary applies here too, even
though this is the fullest access tier.

## Flow docs

| Doc | Covers |
|---|---|
| `ARCHITECTURE.md` | Top-level diagram: storefront, Supabase, both Telegram bots, external services — how the whole system connects |
| `coupon-voucher-lifecycle.md` | How a coupon/voucher code is created, shared (QR code / Telegram deep link), redeemed, and retired |
| `kiosk-sale-flow.md` | Staff recording a sale on the spot via either Telegram bot's Kiosk mode |
| `checkout-payment-flow.md` | Online checkout — Razorpay for India, WhatsApp-enquiry fallback for Australia |
| `stock-intake-flow.md` | New inventory entering the system — direct entry vs. draft-and-approve, and vendor returns |
| `invoice-generation.md` | How a PDF invoice gets generated and attached to a sale |
| `instagram-integration.md` | Event-photo auto-posting and Instagram-linked checkout flows |
| `auth-session-flow.md` | Staff login and session handling, at the shape level |
| `admin-role-gating.md` | What `super_admin` / `owner` / `sales` can each see in `admin.html`, and how that's enforced |

## How to use this with the rest of the knowledge base

The other documents in `chatbot/kb/admin/` (handoff notes, build plans, TODO.md) are
curated copies of real project history — they tell you what was built, when, and why, often
with more narrative color than these flow docs. These flow docs are the complement: a
synthesized, always-current-as-of-authoring picture of each major flow, read directly from
the deployed code rather than from what was written about it at the time.
