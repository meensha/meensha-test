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

**8. The lead that came in through a QR code and went nowhere (added 2026-11-01)**
- At a stall, visitors scan a QR code to register for an offer. The owners expected those people to show up in their "potential customers" list. They did not — the registration saved a discount code but never created a lead. Fixing that was the easy part.
- The sneaky part: a *repeat* scan (same person, same event) took an early-exit path that handed back the existing code and skipped the "add to leads" step entirely. Early returns quietly skip side effects — a good, plain-language lesson for anyone building forms.
- The honest twist: my first fix moved the "add lead" step above the abuse limiter, and an independent reviewer pointed out that anyone holding the public event link could now flood the lead list. Fix: add the lead only after the limiter passes. Worth telling — the reviewer, not the builder, caught it.
- Related clean-up: sharing a visiting card to someone already on the list used to create a second row. Now it updates the same person's entry and keeps a record of when it was shared and the exact message sent.

**9. Letting a customer's own code apply itself — and still asking first**
- Idea: if the number typed at checkout belongs to someone who scanned for an offer, apply their code automatically. Reality check from an independent tester: with no way to say "not this time", staff lose control of which discount goes where. Shipped version: it *asks* ("Apply Saily's code?"), remembers a "no" for that sale, and records on the sale that the discount was suggested automatically so owners can audit it later.
- Same section, a smaller story: the owners wanted a flat "overall discount" on the whole bill, optional, but if used it must be less than the cart total, and it must show on the invoice the customer gets. Optional-but-validated is a surprisingly common requirement; the real work is the invoice math still adding up.

**10. One phone-number rule does not fit two countries**
- India: always +91 and exactly ten digits — strict is right. Australia: add +61 and don't police the length, because real numbers vary. The trap: comparing numbers by "last ten digits" quietly breaks for the looser country, and very short entries can match strangers. The fix was a shared helper and a minimum length, not a bigger rule.

**11. "Send the invoice" turned out to mean two different things**
- A WhatsApp link can pre-fill a message to a specific number but cannot attach a file. The phone's share sheet can attach the actual PDF but cannot pick the chat for you. Choosing between them is a product decision, not an engineering one; the honest answer is to offer both and explain the trade-off. A true one-tap "PDF to this number" needs the paid WhatsApp business interface — name that cost rather than hiding it.

**12. How the work got reviewed (process beat)**
- Every feature went through a builder, then a separate tester and a separate security reviewer working from the code alone, then a final sign-off — not because it's fashionable, but because each round found something the builder had missed (a missing "undo", a spam hole, a stale-data bug).
- Two operational lessons: ship the database change *before* the website code that needs it, and remember the live site can take 10–25 minutes to update after a push — so only update the backup mirror after you've confirmed the change is actually live.

## Possible title options (pick one later)
- "What a Handloom Saree Business Actually Needs From Its Tech Stack"
- "I Built an E-Commerce Backend Around One Idea: No Two Sarees Are the Same"
- "The Boring, Correct Way to Add AI to a Small Business Telegram Bot"
- "The Bug Was in the Early Return: Lessons From a Small Shop's Lead Tracker"

## Tone notes for the actual write-up later
- First-person, founder's voice — not a case study written in third person
- Name real numbers where comfortable (₹ revenue milestones, SKU counts, "43 SKUs, 110 units" is a nice concrete detail) — specificity reads as more honest than vague claims
- Don't over-explain the tech to a non-technical reader, but don't dumb it down either — assume a curious small-business-owner reader, not a fellow engineer
- The strongest material in the whole build is probably section 6 (what broke) — resist the urge to cut it for looking less polished
