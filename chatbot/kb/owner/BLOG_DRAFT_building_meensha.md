# Draft: "How I Built Meensha's Tech Stack" (blog notes, not a finished post)

This is a running set of notes and beats for a future blog post — not written in publish-ready prose yet. Pull from here, don't publish this file as-is. Written from the founder's/builder's point of view, not the technical handoff docs' point of view.

## The angle

Most "how I built my e-commerce store" posts are either "I used Shopify" (nothing to say) or "I built a distributed microservices architecture for my 12-product store" (overkill, dishonest about what a small business actually needs). Meensha's story is the honest middle: a real handloom saree business, real revenue, built on the smallest stack that could actually do the job — and rebuilt in public, in pieces, as real problems showed up. Worth naming explicitly: nothing here was planned end-to-end on day one. Nearly every feature exists because something broke, cost money, or a real customer/staff workflow demanded it.

## Possible structure / beats to hit

**1. Why not Shopify/WooCommerce**
- Cost at small scale (no monthly platform fee, no transaction cut beyond Razorpay's own)
- Full control over the exact reservation/hold logic a physical-inventory handloom business needs (see below) — off-the-shelf platforms assume infinite/warehouse stock, not "one specific hand-woven piece exists"
- Static site (GitHub Pages) + Supabase backend — genuinely simple, genuinely free at this scale

**2. The core insight: physical inventory isn't "stock count," it's individual pieces**
- Batch/unit tracking model: a SKU (product type) vs. individual `inventory_units` (this exact saree, this exact piece)
- Why that matters for handloom specifically: no two pieces are identical, "10 in stock" is a lie a mass-manufactured platform tells that doesn't fit weaving
- Cart reservation holds (15-minute timer) — solves the "two customers add the same one-of-a-kind piece" race condition a normal cart doesn't need to think about

**3. Payments: real Razorpay, not a fake "contact us to pay" flow**
- Started as a placeholder idea, turned out KYC was already done — went straight to the real dynamic Payment Links API
- WhatsApp fallback for Australia (no local payment gateway story yet) — the honest version of "not every market gets the same checkout," not a compromise hidden from the reader

**4. The Telegram bots — staff tooling nobody else talks about**
- Two separate bots (India/Shalini, Australia/Meenakshi) for point-of-sale entry, not a "cool feature" — the actual problem was staff needing to record a sale without opening a laptop
- Draft-first Stock Intake for AU (submissions don't touch real inventory until approved) — a deliberate trust boundary, worth explaining *why*, not just *that*
- The most recent addition: staff (and the owner, via a separate bot) can just ask the bot a question in plain English — "is Ajrak in stock", "sales this week" — instead of hunting through button menus. Worth a whole section on the guardrail: the AI never touches the database directly, it only ever picks from a fixed list of safe, pre-built lookups. That's the actual interesting engineering decision, more than "we added AI."

**5. The auth story — a good "we changed our mind and that's fine" beat**
- First design: WhatsApp OTP login. Then realized it costs real money per message (Business API providers charge per authentication message) — email OTP is free.
- Second design, deployed: signup with email verification + password, login without OTP at all (WA number or email + password), forgot-password via email OTP. Good story beat: "we shipped the simpler, cheaper version once we actually priced out the fancy one."

**6. What almost went wrong (the honest failure-mode section — readers trust this more than a highlight reel)**
- The AU Telegram bot was silently completely broken for several hours after a routine deploy — a platform default (JWT verification) changed under us, and a webhook that gets no auth header from Telegram just… stopped working, no visible error anywhere. Good illustration of "working in production" vs. "worked when I tested it."
- A mislabeled credentials file (a key named `SERVICE_KEY` that was actually the anon key) caused a cleanup script to silently do nothing while reporting success — RLS with zero policies just returns "200, nothing happened" instead of erring loudly. Worth a paragraph on why fail-loud beats fail-quiet, and why it's tempting to build fail-quiet systems by accident.

**7. The "monitor your own business" layer**
- A dedicated, separate Telegram bot (MeenshaMonitor) purely for owner-facing visibility — sale notifications mirrored from both regional bots, a daily tech-health digest (is the site up, is Razorpay reachable, is GitHub Pages serving), all running on Supabase's built-in cron rather than a separate server
- The deliberate choice not to over-build this: no dashboard, no separate monitoring server, no vector database for "AI knowledge base" — just a bot that answers real questions from real (small) structured tables, because that's genuinely what the business needed, not what would look impressive in a portfolio

## Possible title options (pick one later)
- "What a Handloom Saree Business Actually Needs From Its Tech Stack"
- "I Built an E-Commerce Backend Around One Idea: No Two Sarees Are the Same"
- "The Boring, Correct Way to Add AI to a Small Business Telegram Bot"

## Tone notes for the actual write-up later
- First-person, founder's voice — not a case study written in third person
- Name real numbers where comfortable (₹ revenue milestones, SKU counts, "43 SKUs, 110 units" is a nice concrete detail) — specificity reads as more honest than vague claims
- Don't over-explain the tech to a non-technical reader, but don't dumb it down either — assume a curious small-business-owner reader, not a fellow engineer
- The strongest material in the whole build is probably section 6 (what broke) — resist the urge to cut it for looking less polished
