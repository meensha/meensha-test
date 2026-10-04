# Architecture — How the Pieces Connect

One diagram, meant to be readable without an engineering background: what the major pieces
of Meensha's tech stack are, and how they talk to each other.

```mermaid
flowchart TB
    Customer["Customer<br/>(browser / WhatsApp)"]
    Staff["Staff<br/>(Shalini / Meenakshi, via Telegram)"]
    Dheeraj["Dheeraj<br/>(admin.html, super_admin)"]

    subgraph Storefront["Storefront — static site, GitHub Pages (free hosting)"]
        IndexHTML["index.html<br/>shop, cart, checkout"]
        ProductPages["product.html, /sarees/* pages"]
        AdminHTML["admin.html<br/>inventory, sales, P&L, roles"]
        InvoiceHTML["invoice.html<br/>customer invoice lookup"]
    end

    subgraph Supabase["Supabase — one backend project"]
        DB["Postgres database<br/>(inventory, sales, coupons, settings, sessions...)<br/>Row-Level Security on every table"]
        EdgeFns["Edge Functions<br/>(serverless TypeScript — payments, bots, PDFs, digests)"]
        Storage["Storage<br/>(product photos, generated invoice PDFs)"]
    end

    IndiaBot["Telegram Bot — India<br/>(Shalini, @meenshashalbot)"]
    AUBot["Telegram Bot — Australia<br/>(Meenakshi, @meenshaozbot)"]
    MonitorBot["MeenshaMonitor<br/>(owner-facing alerts & digests)"]

    Razorpay["Razorpay<br/>(India online payments)"]
    OpenRouterGemini["Gemini / OpenRouter<br/>(bot Q&A, price benchmarking)"]
    Anthropic["Anthropic API<br/>(invoice/receipt scan, product descriptions)"]
    InstagramAPI["Instagram Graph API<br/>(event-photo auto-posting)"]
    WhatsApp["WhatsApp<br/>(order messages, enquiries, invoices)"]

    Customer -->|browses, checks out| IndexHTML
    Customer -->|product page, invoice lookup| ProductPages
    Customer -->|order / enquiry message| WhatsApp
    Staff -->|record sales, stock, vouchers| IndiaBot
    Staff -->|record sales, stock, vouchers| AUBot
    Dheeraj -->|manage everything| AdminHTML

    IndexHTML <-->|anon key, RLS-scoped reads/writes| DB
    AdminHTML <-->|admin-session-scoped calls| DB
    AdminHTML -->|generate link, print voucher| EdgeFns
    InvoiceHTML --> EdgeFns

    IndiaBot <-->|service-role access| DB
    AUBot <-->|service-role access| DB
    IndiaBot --> EdgeFns
    AUBot --> EdgeFns
    MonitorBot <-- "sale/activity notifications, daily digests" --- EdgeFns

    EdgeFns --> Storage
    EdgeFns <--> DB
    EdgeFns -->|create payment link, verify webhook| Razorpay
    EdgeFns -->|answer staff Q&A, price suggestions| OpenRouterGemini
    AdminHTML -->|AI scan / describe| Anthropic
    EdgeFns -->|auto-post event photos| InstagramAPI
    IndiaBot -->|send order/invoice links| WhatsApp
    AUBot -->|send order/invoice links| WhatsApp
    Razorpay -->|payment webhook| EdgeFns
```

## Reading this diagram

- **Storefront** is just static files — no server of its own. It talks directly to Supabase
  using the public anon key, with Row-Level Security deciding what that key is allowed to
  see or change. `admin.html` is the same idea, but every call also carries a logged-in
  admin session token, which Supabase checks before allowing anything sensitive.
- **Supabase is the one real backend.** There is no separate staging backend — the staging
  and production *websites* are separate (two GitHub Pages sites), but they both talk to
  the same underlying Supabase project. Any database change or Edge Function deploy is live
  everywhere immediately.
- **Edge Functions** are where anything that needs a secret, needs to call an external
  service, or needs to run with elevated (service-role) database access actually happens —
  creating a Razorpay payment link, verifying a payment webhook, generating an invoice PDF,
  posting to Instagram, sending a Telegram message, running a scheduled digest.
- **Both Telegram bots** are themselves Edge Functions (webhook-triggered), with their own
  service-role access to the database — staff interact with the business entirely through
  chat, without needing to open a laptop.
- **MeenshaMonitor** is a third, separate bot that only receives information (sale copies,
  activity summaries, health digests) — it's Dheeraj's visibility layer, not a staff tool.
- **External services** are each used for exactly one job: Razorpay for India online
  payments, Gemini for the bots' natural-language Q&A and AI price suggestions, Anthropic's
  Claude for the admin panel's invoice/receipt-scanning and product-description features,
  the Instagram Graph API for auto-posting event photos, and WhatsApp as the universal
  fallback for anything that isn't a fully online transaction.
