# Instagram / Social Integration

Two separate Instagram-related flows exist today.

## 1. Event-photo auto-posting

```mermaid
sequenceDiagram
    participant V as Visitor
    participant Page as event-photos.html
    participant DB as Supabase
    participant Fn as event-photo-submit (Edge Function)
    participant IG as Instagram Graph API

    V->>Page: logs in (real customer account), submits a photo + caption + optional @handle
    Page->>DB: stores the photo (unposted)
    Note over DB: once 4 unposted photos have accumulated for an event...
    DB->>Fn: batch of 4 triggers posting
    Fn->>IG: create a per-photo carousel-item container
    Fn->>IG: create the carousel container (captioned with contributors' names/handles)
    Fn->>IG: publish
    Fn->>DB: mark those photos posted + record the resulting Instagram post id
```

This only works once Instagram Graph API access is actually set up (Business/Creator
account linked to a Facebook Page, a Meta Developer App, a long-lived access token) — the
code path is fully built, but silently does nothing until those credentials exist. See
`INSTAGRAM_INSIGHTS_SETUP.md` in this knowledge base for the setup steps.

## 2. Instagram-linked checkout ("Insta link" / "Insta checkout-link")

A separate, simpler flow: staff (via the India bot or `admin.html`) generate a direct
`meensha.in/index.html?buy=<sku_id>` link for a single item, meant to be pasted into an
Instagram post/story/bio-link. Tapping it auto-adds that exact item to the visitor's cart
and opens checkout immediately — no payment link is pre-created, and no placeholder
customer record is needed, since the real buyer's details only show up once they actually
start checking out.

## What's shared between the two

Both flows exist because Instagram is a major sales channel for Meensha, but neither
depends on the other — auto-posting needs the Graph API setup above; the checkout-link
flow works today with zero extra setup (it's just a URL with a query parameter and an
existing cart-loading code path).
