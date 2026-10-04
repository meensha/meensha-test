# Draft — Medium post #2 (series continuation from "I Built an Ecommerce Platform Using Claude, Supabase, and Netlify")

Status: DRAFT, ready for Dheeraj's review/edit pass before publishing. Built from the beats in `BLOG_DRAFT_building_meensha.md` (esp. section 6, flagged there as the strongest material — kept front and center here). Not yet posted to Medium.

---

## Working title

**"No Two Sarees Are the Same — What That Means When You Let AI Build Your Inventory System"**

(Alternates from the earlier notes file, still on the table: "The Boring, Correct Way to Add AI to a Small Business Telegram Bot")

---

## Draft body

The first post in this series ended with an honest admission: the platform wasn't done. It still isn't. But "not done" turned out to be the wrong thing to worry about. The real lessons showed up in the parts that broke.

Here's the one I didn't expect going in: **the hardest problem wasn't payments, or auth, or even the AI. It was the idea of "10 in stock."**

—

**THE PROBLEM MOST E-COMMERCE PLATFORMS DON'T HAVE**

Every off-the-shelf platform — Shopify, WooCommerce, the rest — is built around a quiet assumption: a product is a number. You have 10 of something. Someone buys one, you have 9. The platform doesn't care which one they got, because they're identical.

A handloom saree is not identical to the next one off the same loom. Two pieces from the same weaver, same pattern, same day, are still two different physical objects — different drape, different minor variation, sometimes a genuinely different piece entirely once you're past the first unit. "10 in stock" isn't a simplification for this business. It's a lie the software tells because that's the only sentence it knows how to say.

So the actual data model isn't "product + quantity." It's a SKU (the pattern, the type) sitting above a set of individual `inventory_units` — this exact piece, that exact piece, each one trackable on its own. Claude didn't propose this on the first pass. I had to explain, more than once, that "stock count" was the wrong abstraction before the architecture actually fit the business. That's worth saying plainly: the tool optimizes for the problem as stated. If you state it wrong, it builds the wrong thing correctly.

Once that model existed, a new problem showed up immediately: two customers, same one-of-a-kind piece, same minute. A normal cart doesn't need to solve this — normal carts have infinite stock. This one needed a reservation hold, a 15-minute timer, a real answer to "what happens when both of them hit buy." That's not a feature you get from a template. It's a feature you get from actually sitting with what "one saree" means.

—

**WHAT BROKE — AND WHY IT'S THE MOST USEFUL PART OF THIS STORY**

Readers trust a build story more when it includes the failures, so here are two, plainly.

*The bot that silently died.* The Australia-facing Telegram bot — the one staff actually use to record real sales — went completely dark for several hours after a routine deploy. Not an error. Not a crash. Just… nothing. It turned out a platform default (JWT verification) had quietly flipped back on during redeploy, and a Telegram webhook doesn't send an auth header — so every incoming message was rejected before it ever reached the code, with no visible signal anywhere that anything was wrong. The lesson wasn't "check your deploy flags." It was smaller and more uncomfortable than that: *working in a test yesterday says nothing about working right now*, and a system that fails silently will stay broken exactly as long as nobody happens to look.

*The script that lied about succeeding.* A cleanup script used a credential labeled `SERVICE_KEY` that was, in fact, the public anon key. With zero database policies granting that key write access, every delete request the script sent came back `200 OK` — and did absolutely nothing. No error. No warning. Just a script that reported success while quietly accomplishing none of its job. That one stuck with me more than the outage did, honestly, because it's the failure mode that's *designed in* by default: permission systems that fail closed tend to fail silently, and silence reads as success unless you go looking for the absence of an effect, which is a much harder thing to notice than an error message.

Neither of these is a story about AI getting something wrong. They're both stories about production being a different environment than a test run, and about systems that don't tell you when they've failed — which is a problem with or without an AI in the loop. The AI just built the system fast enough that I hit both lessons in the same month instead of the same year.

—

**THE AI THAT ONLY ANSWERS, NEVER TOUCHES**

The most recent addition to the stock is the smallest-sounding one and the one I'd defend hardest: staff can now ask the Telegram bot a plain-English question — "is Ajrak in stock," "sales this week" — instead of hunting through button menus.

The interesting decision isn't that there's a language model answering questions. It's the guardrail underneath it: **the model never touches the database.** It picks, every time, from a fixed list of pre-built, safe lookup functions — the same functions a button-menu version of the bot would call. There is no path from "customer types a sentence" to "arbitrary query runs against production data." If the model can't map the question to one of the approved lookups, it says so, instead of improvising something clever and wrong.

That's the actual engineering decision worth talking about — not "we added AI," but "we added AI with no more authority than the menu it replaced."

—

**WHAT THIS ADDS TO THE EARLIER LESSON**

The first post argued that the bottleneck in AI adoption is clarity, not capability — that "build an ecommerce platform" gets you something generic, and a precisely stated problem gets you something real.

Here's the addition, six weeks and several outages later: **clarity has to survive contact with production, not just contact with the first draft.** The inventory model was right the second time I explained it. The JWT default was right until a routine redeploy quietly changed it. The credential was labeled correctly right up until it wasn't the thing its label said it was. None of these are failures of the tool. They're the actual shape of running a real system — the same shape it would have if a team of senior engineers had built it, just compressed into a timeline where one person, working with Claude, hits all of it directly instead of hearing about it secondhand from a postmortem doc three teams over.

The platform is still not finished. Good — that was always going to be the honest answer. But it's a little more honest now about what "finished" was never going to mean for a business built on the idea that no two of anything are quite the same.

If you've hit a version of the "fails quietly, reports success" trap in your own systems — AI-built or otherwise — I'd like to hear it. That failure mode seems to be one of the more universal ones, and I don't think it gets talked about enough next to the louder, more dramatic outage stories.

#AI #EcommerceDevelopment #Technology #SoftwareArchitecture #SmallBusiness #ProductDevelopment

---

## Notes for Dheeraj's edit pass

- Kept the physical-inventory beat and the two failure stories from the notes file as the spine — the notes file specifically flagged section 6 (failures) as the strongest material, so it's front-loaded rather than buried at the end like post 1's structure did.
- Left out payments/auth/monitoring beats from the notes file entirely — there's enough here for one post; those are natural material for a post #3, not squeezed into this one.
- Didn't reference today's session (the multi-agent collision/reconciliation, the staging-vs-production discovery) — that's a genuinely good, very on-theme story for a *future* post once it's actually resolved rather than mid-flight, not this one. Flagging it here so it doesn't get lost: **"what happened when two AI agents fixed the same problem without knowing about each other"** is a strong post #3 or #4 title once the staging separation work lands.
- Numbers are intentionally still vague ("several hours," not a specific figure) — the notes file said real numbers read as more honest; add real ones here before publishing if comfortable (actual SKU/unit counts, how long the AU bot was actually down).
