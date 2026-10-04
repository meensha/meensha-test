# Instagram post-views integration — what you need to set up first

Requested: daily summary including view counts for the latest 2 Instagram posts. This isn't something that can be scraped or pulled from a public URL — view/impression counts are private metrics only exposed through Meta's official Instagram Graph API, and only for accounts set up correctly.

## What you need, in order

1. **Convert `@meensha_fabrics` to a Business or Creator account** (Instagram app → Settings → Account type). Personal accounts have no API access to insights at all.
2. **Link it to a Facebook Page** — the Graph API authenticates through a Facebook Page connected to the Instagram account, not the Instagram account directly.
3. **Create a Meta Developer App** at developers.facebook.com — add the "Instagram Graph API" product to it.
4. **Generate a long-lived access token** with the `instagram_manage_insights` permission, scoped to that Page/Instagram account. Meta's tokens expire (long-lived ones last ~60 days) — this needs periodic renewal, or a refresh flow.
5. Depending on your Meta App's review status, some permissions may require **App Review** (Meta manually approving your use case) before they work outside a small test-user allowlist.

## Once that exists

Hand me: the Instagram Business Account ID, the access token (as a Supabase secret, never pasted in chat), and confirmation of which permission was granted. I can then build a small Edge Function that calls `GET /{ig-user-id}/media` for the latest 2 posts, then `GET /{media-id}/insights?metric=impressions,reach` (or `plays` for Reels) for each, and fold the numbers into the same daily digest the visitor counter reports through.

## Why not scrape instead

Instagram actively blocks scraping (rate-limits, IP blocks, and can flag/restrict accounts that trigger their anti-scraping detection), view counts specifically aren't even present in a logged-out page's HTML, and any numbers pulled that way would be unreliable/stale. Not worth the risk to your account for numbers the official API gives you correctly once set up.
