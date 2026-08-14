# Meensha Ecom Site: Monitoring + Daily AI Summary Architecture

Scoped 2026-07-12 (split out from the homelab plan doc — this is a separate business, kept segregated from the family homelab).

## Gitea now available for this project (added 2026-07-13, from the homelab session)
A private Gitea instance is running on the homelab (`https://gitea.home.bhartis`), with a `meensha-ecom` repo already created and pushed once (planning docs: this file, MASTER_PLAN, initial_plan, Project Brief — **not** the live site code, which stays in its own `github.com/meensha/meensha-test` repo, untouched and not mirrored here).

**To push CT102/monitoring work into it:**
- Credentials are in a local-only file: `~/Claude Projects/Meensha/.gitea-credentials` (never committed, never pasted into chat — read it directly with the Read tool when needed)
- Token is scoped to `write:repository` only — can't touch other repos or admin settings
- Clone/push pattern is documented in that credentials file directly (uses `-c http.sslVerify=false` for the self-signed cert and a `Host` header override since DNS may not resolve `gitea.home.bhartis` from every context — same pattern used successfully from the homelab session)
- Suggested content to add: this doc, plus CT102 configs (Kuma setup, dhclient.conf fix, nginx config) once finalized, redacting secrets the same way the homelab repo does (`${PLACEHOLDER}` style) — a `SCRUB-CHECKLIST.md` already exists in the homelab repo as a reference pattern if useful here too

## Git flow: GitHub stays staging, Gitea becomes an approved-copy archive (corrected 2026-07-13)
Earlier framing (Gitea as the staging target) was wrong — **`meensha-test2` on GitHub (`github.com/meensha/meensha-test2`, already exists as a remote) is the actual staging environment**, no new staging build needed. The real flow:

1. **Develop/test on `meensha-test2`** (GitHub) — this is where changes get tried first, as already established
2. **Once a change is approved on test2** → push a copy to Gitea's `meensha-ecom` repo, maintained with a local changelog — this is an *archive of approved-staging state*, not a live staging target itself
3. **When a tested change is promoted from test2 to the real production repo** (`meensha/meensha-test`, the live site) → that final state also gets recorded in Gitea, separately from the staging-approved copies — so Gitea ends up holding both "approved staging" and "final/production" snapshots over time
4. **Anonymization is its own separate stack/track**, independent of this flow — not something that blocks or entangles with normal dev/staging/production work. It's a distinct effort for eventually publishing a sanitized write-up, run on its own timeline once there's something worth writing about.

**Still true from the original framing**: `meensha-test` (production) has uncommitted local work sitting in it (2 commits ahead of origin + untracked `setup/*.sql`) — reconcile that before treating any promotion-to-production step as clean. This whole flow is this project's own git workflow decision, not something the homelab session should implement unilaterally — the Gitea repo/credentials are ready (see section above) whenever this session wants to start using them per the flow above.

## Actual stack (confirmed by reading the repo — not Shopify/WooCommerce as originally assumed)
Static frontend (`index.html`/`admin.html`) on GitHub Pages, custom domain `meensha.in` (CNAME), backend = **Supabase** (hosted Postgres + auto-generated REST API), payments via Razorpay, AI (product benchmarking) via Gemini free tier. Zero self-hosted backend to instrument — everything is reachable via Supabase's REST API with an API key. Confirmed tables: `sales` (date, total, paid, balance, mode, shipping_status, gst — the transaction data source), `requests` (WhatsApp product inquiries), `purchases` (cost of goods), `overheads` (expenses). No visits/events table exists yet.

**Known operational risk (from Meensha's own master plan doc):** Supabase free tier auto-pauses after ~1 week idle — already bit them once ("Blocked 🔴 Supabase paused → resume first"). This is exactly what monitoring should catch automatically instead of being discovered manually.

## Segregation from the personal homelab — DECIDED: dedicated container AND dedicated bot
Meensha is a **separate business** — decided 2026-07-12 to use a fully dedicated LXC container (CT102, `meensha-monitor`), not sharing CT100's Kuma instance or its Telegram bot. Rationale: today's real ~6h Immich/Vaultwarden outage on CT100 demonstrated that same-host monitoring shares a blast radius with whatever it's supposed to be watching — a dedicated container keeps Meensha's alerting independent of any homelab incident (and can even alert *about* a homelab problem from outside it).

**2026-07-16 note:** the token first provided for this (`@hmlabbot`) turned out to be the existing homelab alerts bot, not a new one — caught before wiring anything in. Confirmed: Meensha needs its **own** bot, separate from `@hmlabbot`. Still waiting on that token.

**Built so far (2026-07-12):**
- CT102 `meensha-monitor`, Debian 13, IP `192.168.1.57` — confirmed running
- Docker + Uptime Kuma running (container `meensha-kuma`, port 3001) — confirmed healthy
- nginx + a **separate mkcert CA** (not the homelab's `*.home.bhartis` cert — its own local CA) reverse-proxying to Kuma
- DNS entry added in AdGuard: `meensha-monitor.home.bhartis` → `192.168.1.57` — confirmed resolves correctly

**Correction (verified independently from the homelab-side session, same day):** the "correct DNS from creation" claim above wasn't accurate when checked — CT102's LXC-level `nameserver`/`searchdomain` config *was* set correctly (192.168.1.10 + 100.100.100.100 fallback), but the running container's actual `/etc/resolv.conf` didn't match it, and survived a full `pct reboot 102` still wrong. Root cause: CT102 uses classic `ifupdown`/`dhclient` for `eth0` (`iface eth0 inet dhcp`), which pulls DNS servers from the home router's own DHCP response (`hgu_lan` domain) and silently overwrites whatever the LXC-level config intends — this is a different failure mode than CT100's Tailscale-accept-dns issue, not the same bug recurring. Fixed by adding `supersede domain-name-servers 192.168.1.10, 100.100.100.100;` and `supersede domain-name`/`domain-search "alai-mimosa.ts.net";` to `/etc/dhcp/dhclient.conf`, then `dhclient -r eth0 && dhclient eth0` (no reboot needed, Kuma stayed healthy throughout). Verified via `getent hosts` inside the container and a live `curl` to `https://meensha-monitor.home.bhartis` (returns Kuma's normal 302, not the earlier 502 that a mid-restart race had produced). This kind of "config says X, running system does Y" gap is exactly what this session's earlier work on the homelab side (CT100 DNS, the whole rubric/grading saga) kept finding — worth verifying live state rather than trusting what a config *should* produce, including in future Meensha-side sessions.

**Still needed to complete the pipeline:**
- Kuma initial setup (create admin account — first-run, needs to happen once from a browser)
- A **Telegram bot dedicated to Meensha** (separate from any homelab bot) — create via @BotFather, paste token into Kuma's notification settings
- Supabase read-only API key (scoped to `sales`/`requests`/`purchases`/`overheads`, plus `events`/`daily_snapshots` once those tables exist) for the daily/weekly summary script
- The daily/weekly Python script itself + systemd timer (same pattern as the homelab's grader script), to be written once the above two are available

## Architecture

### 1. Uptime monitoring (Kuma) — LIVE as of 2026-07-12
Two monitors running on CT102's Kuma (`meensha-monitor.home.bhartis`):
- `https://meensha.in` — site up, 100% uptime so far, cert expiry tracked automatically (57 days left as of setup)
- Cross-monitor: CT102 ↔ CT100's Kuma watch each other, so a Kuma outage on either side gets caught by the other instead of going silent
- **Still needed**: a Supabase-specific check (e.g. `HEAD` on a small table) to catch the auto-pause scenario specifically, since the frontend can look "up" (static GitHub Pages) while the DB behind it is paused — blocked on having the Supabase project URL/key
Alerts via a Telegram bot **dedicated to Meensha** (separate from the personal homelab bot) — bot itself not yet created.

### 1b. Interactive Telegram bot (not push-only) — scoped 2026-07-12
Beyond just alerting on downtime, the bot should answer on-demand questions via a button menu, not just send scheduled digests. Two separate processes on CT102:
- **Daily/weekly cron** (already scoped below): computes and *stores* each day's aggregates into `daily_snapshots` — this is the archive the bot reads from.
- **New: always-running bot listener** (systemd service, not a timer — needs to stay up to receive taps): responds to inline-keyboard button presses by querying `daily_snapshots` directly (fast, no recomputation), falling back to a raw `sales`/date-range query for anything outside the snapshot history (e.g. "sales in March").

**Suggested menu (8 buttons, each answer kept to 3-4 lines — a quick check, not a report):**
1. Today's Sales — revenue, order count, avg order value, top-selling item
2. Last 7 Days — total revenue, trend vs. previous week (%), best single day
3. This Week P&L — revenue − COGS − overheads, split India/Australia
4. Month-to-date / Since-launch P&L — the running total view
5. Pending Collections — total unpaid balance, and the oldest unpaid order
6. Open Inquiries — unanswered `requests` count + how long the oldest has waited
7. Top Products This Week — by revenue and by units side by side (restock signal)
8. Low Stock Alert — from `inventory`'s reorder thresholds (table already exists)

### 2. Business analytics events (doesn't exist yet — needs adding)
Not just pageviews — a general-purpose `events` table:
```sql
event_type text, item_id text, meta jsonb, referrer text, geo text, device text, created_at timestamptz
```
Fed by a small JS snippet on storefront pages, capturing: `page_view`, `product_view` (which SKU), `add_to_cart`/buy-now click, `checkout_started` (ties to an eventual `sales` row = conversion), `social_share` (platform + item — WhatsApp/Instagram/Facebook share-button clicks), `search` if a search box exists. One flexible jsonb-payload table rather than a rigid schema per event type, so new event kinds can be added later without migrations. No new service, no self-hosted analytics (Plausible/Umami) — stays consistent with the site's own zero-cost goal.

**Business-viewpoint reporting this unlocks:** top-viewed vs. top-purchased products (conversion rate per SKU), cart-abandonment rate, traffic source split (social vs. direct vs. search, via referrer/UTM), social-share counts per platform per product (virality signal), India vs. Australia geo split (matches the dual-market storefront), device split (mobile vs. desktop), inquiry-to-sale conversion (linking `requests` to `sales`).

**Sales + P&L (daily and cumulative):** daily sales total (today vs. yesterday vs. same-day-last-week trend), and profit/loss = `sales.total` − matching `purchases` (COGS) − `overheads` — both **overall** and **split India vs. Australia** (needs a confirmed field to key off — a market flag on `sales`, or derivable from `mode`/currency/customer country; confirm the exact column before building the query). Report both today's P&L and the running total so far (month-to-date / since launch).

### 3. Daily/weekly transaction + inquiry summary
A small script (script + systemd timer, matching the pattern already used for the homelab's Moodle grader) that:
- Queries Supabase's REST API for `sales`, `requests`, and `events` using a read-only API key
- Computes totals: revenue, order count, avg order value, payment mode split, pending balance, new inquiry count, plus the conversion/traffic/social metrics above
- Feeds the numbers to an LLM for a short write-up — **the AI's job is to simplify for action, not report data**: lead with what changed and what to do about it (e.g. "Revenue up 20% this week, driven by the Ajrak saree — restock it" / "Cart abandonment jumped on mobile — worth checking the checkout flow" / "3 requests unanswered for 2+ days"), not a table of numbers. Raw metrics stay queryable in Supabase for anyone who wants to dig in; the Telegram message is a business owner's 30-second read.
- Posts to the Meensha-dedicated Telegram bot.

### Where compute happens, and which AI
All data pulling and number-crunching (Supabase queries, revenue/P&L/conversion calculations) runs entirely locally — no external API involved in that part. Only the final "turn numbers into a sentence" step touches an LLM: **local Ollama is the default** (zero cost, business data never leaves the network). Gemini (already used elsewhere in the Meensha stack for product benchmarking, so not a new trust boundary) is kept as an optional fallback only if Ollama's write-up quality proves too weak — not a default, to keep external API calls minimal.
Recommendation: **share one Ollama instance** across homelab + Meensha use cases rather than running two — the AI engine itself is a stateless inference call with nothing of Meensha's persisted afterward, so duplicating it just to preserve segregation would double RAM pressure for no real isolation benefit. Segregation should mean separate bot/container/data paths, not necessarily a second AI engine.

### Two-tiered reporting (daily brief vs. weekly detail)
- **Daily (Telegram message)**: short, plain-language, business-only terms — no tech-stack talk (no mention of Supabase/tables/queries). Today's sales, P&L, and **any issues called out first and clearly** (e.g. a ⚠️ line at the top: "⚠️ 3 requests unanswered 2+ days" / "⚠️ Cart abandonment up on mobile"), followed by the brief action-oriented summary.
- **Weekly (PDF report)**: the full detail — sales/P&L trend (overall + India/AU split), product conversion table, traffic/social/device breakdown, inquiry funnel — generated once a week via a lightweight markdown→PDF step (e.g. `pandoc` or `weasyprint`), sent as a Telegram document attachment (or emailed). Clear section headings, issues/red-flags highlighted at the top too, numbers and charts below for whoever wants to dig in.

### Better than a static PDF? A locally-hosted historical dashboard
A PDF is a fine low-effort starting point but doesn't build a queryable history. Better long-term shape:
- Add a small `daily_snapshots` table in Supabase storing each day's *computed* aggregates (revenue, P&L, conversion rate, traffic split, etc.), written by the same daily script.
- Build a simple self-hosted dashboard (static HTML + Chart.js, reading straight from Supabase's REST API — no separate backend needed) showing trends over time (this week vs. last month vs. since launch) rather than a single point-in-time snapshot.
- Telegram stays for **push** (immediate, "look now"); the dashboard is for **pull** (deeper, on-demand pattern analysis) — the two complement each other. Treat this dashboard as a phase-2 add-on once the daily/weekly script + snapshot table are working; the PDF can still exist as a shareable export generated from the dashboard's data.

## Compute load estimate (given AI is also planned on the homelab side)
Homelab host: Ryzen 7 5700U (8c/16t), 16GB RAM.
- New segregated container (Kuma + script/timer, no AI): ~250–400MB RAM idle, negligible CPU — polling + a once/twice-daily script run.
- AI summary generation: the real cost, not the container. A loaded 3–4B Ollama model needs ~2–4GB RAM while generating, for maybe 10–30 seconds once or twice a day, then unloads.
- Don't run a second full Ollama instance just for segregation — see recommendation above.

## Division of work
- **Supabase-side** (schema + API key provisioning): belongs in this Meensha project's own chat/session, since it touches the live ecom schema — add the `events` and `daily_snapshots` tables here, issue a read-only API key scoped to `sales`/`requests`/`purchases`/`overheads`/`events` for the reporting script.
- **Homelab-side** (Kuma monitors, the summary script, Telegram bot, Ollama integration): lives in the homelab project, using the same systemd-timer + Ollama + Telegram pattern as the homelab's own monitoring — separate bot, separate container/data paths, per the segregation requirement above.

## Open items before building
1. Exact degree of infra segregation (dedicated container vs. same host, separate paths) — not yet decided.
2. Which column (or derivation) identifies India vs. Australia per sale, for the P&L market split.
3. Whether a search box exists on the storefront (affects whether `search` events are captured).
