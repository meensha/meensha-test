# Meensha — Handoff / Current State (2026-09-27)

Session note — supersedes `MEENSHA_HANDOFF_2026-09-13.md` as the living
status doc. Everything from before this session still holds; not repeated
here. Also check `meensha-test/TODO.md` — the live day-to-day tracker,
updated more often than this doc (per the standing convention).

## New this session

**"Add photo to item" — both bots.** Shalini/Meenakshi can add photo(s) to an
already-approved existing SKU (Maintenance menu → "📷 Add photo to item"),
distinct from the new-item intake flow's photo step, which only ever ran on
a brand-new item mid-purchase. Reachable two ways: browsing a picker
(defaults to items with zero photos), or a Telegram deep link
(`t.me/<bot>?start=photo_<sku_id>`) that jumps straight to one item.

**Telegram deep links** — `/start` handling in both bots now accepts a
payload (`t.me/<bot>?start=<payload>`), not just a bare `/start`. Two
payloads wired so far: `photo_<sku_id>` (both bots) and `aucost_<sku_id>`
(India bot's existing "Pending AU costs" flow, refactored into a shared
`startAucost` helper reused by both the deep link and the original picker
callback).

**Digests now link straight to the fix, and reach the right bot.**
`daily-health-check`'s missing-photo digest now splits by region
(`india_available`/`au_available`) and — a real gap fixed — actually sends
the AU-relevant half to Meenakshi's AU bot chats too; previously that
digest only ever reached Shalini's bot and MeenshaMonitor, even though it
already scanned AU-available SKUs. Every listed item carries a deep link
straight into "add photo to item" for that SKU. `pending-cost-digest`
(India-side, AU-market purchase costs) got the same treatment — each line
now links to `aucost_<sku_id>`.

**Keyword command-palette + greeting handling, both bots.** New shared
module `supabase/functions/_shared/menuSearch.ts`. Typing a plain keyword
("voucher", "event", "photo", etc.) or a greeting ("hi") now surfaces
matching menu buttons — tapping one goes straight into that flow, same as
tapping it from the real menu — checked *before* falling through to the
existing Gemini natural-language Q&A fallback in both bots. Multiple
matches (e.g. "photo" hits both "Add photo to item" and "Event photo
submissions") show as multiple buttons, deliberately.

**Real bug found + fixed via an independent QA pass.** Spawned a QA
subagent to verify the above end-to-end before shipping (matches the
build-agent → QA-agent → report pattern from the 09-13 session). It found
a genuine lost-update race in the new photo-upload path: both bots wrote
photos via read-session-state → append-in-memory → overwrite-the-whole-
column, so two photos sent back-to-back could race and the second write
would silently drop the first. Fixed with a new `append_sku_photo(p_sku_id,
p_url)` RPC that does the append as one atomic `UPDATE ... photos = photos
|| jsonb` statement (see `setup/add_append_sku_photo.sql`) — verified live
by firing two concurrent appends at a real SKU and confirming both photos
landed (then cleaned up the test data). Both bots now call this RPC
instead of the old read-modify-write.

**Multi-agent collision, again — same pattern as 09-13, handled cleanly
this time.** Pushing this session's commit to `test2` was rejected
(non-fast-forward) — the autonomous cloud routine had pushed a TODO.md
housekeeping commit in the meantime. Fetched, confirmed it touched a
different file with no overlap, merged cleanly (`git merge`, no conflicts,
no force-push), then pushed the merge to all three remotes. Worth
repeating from the 09-13 note: the cloud routine and any manually-driven
session can both be touching `test2` at once — always fetch and diff
before assuming a push will be a fast-forward.

**Owners notified.** Sent a consolidated summary of everything above to
Shalini's bot chats, Meenakshi's bot chats, and MeenshaMonitor, via a
temporary disposable broadcast utility (`send-broadcast`, deployed
`--no-verify-jwt`, deleted immediately after use — same one-off-utility
discipline as `send-monitor-message` before it: never leave a no-auth
broadcast-to-real-owner-phones endpoint standing).

## Continued, later same day — SEO indexing fix

**Checked GSC performance + indexing data (Dheeraj's own login, screen-shared).**
Baseline as of 2026-09-27: only ~2 pages actually indexed; Page Indexing
report showed 2 URLs as "Alternative page with proper canonical tag" and
16 as "Discovered — currently not indexed". Root cause found: `index.html`
had a **static** canonical/title/meta-description, identical on every URL
including the 15 `?shop=<term>` category pages added to sitemap.xml on
2026-09-15 — so Google correctly treated every category URL as a duplicate
of the homepage and refused to index it separately.

**Fixed**: new `updateMetaForShopTerm()` in `index.html` sets
canonical/title/description/OG/twitter tags dynamically per `?shop=` term
on page load. Weaker than server-side rendering (Google's JS execution for
canonical tags is a real but lower-confidence signal), but a strict
improvement over the previous state. Verified end-to-end: local static-file
test, then live on `test2` staging (`https://meensha.github.io/meensha-test2/`),
then live on `origin` production — each confirmed via a real JS check
against `?shop=Kalamkari`/`?shop=Mangalgiri` reading `document.title` and
the canonical `<link>`'s actual `href`, not just grepping for the function
name in the HTML source.

**Two GSC follow-up reminders scheduled** (cloud routines, one-time,
`run_once_at`, not recurring):
- `trig_01XKfBZLaEMHnBb6ctcfmtJu` — fires 2026-09-22 *(already elapsed by
  the time of this handoff; check if it delivered)* — general GSC
  performance baseline follow-up.
- `trig_01Dkj5283pX36qSL7Z8StgiY` — fires 2026-10-01 — specifically checks
  whether the canonical-tag fix above actually moved the indexing counts.

Both are reminder-only routines — they cannot access GSC themselves (no
login), they just prompt Dheeraj to check and tell him what changed since
the recorded baseline.

## Known gaps / open items

- Category-page indexing fix (above) is deployed and verified to render correctly, but whether it actually gets Google to index the 15 category URLs is unconfirmed — that takes real crawl time. Check the 2026-10-01 reminder's outcome; if the "Discovered — not indexed" count still hasn't moved by then, the next thing to check is whether Googlebot's crawler is actually executing the page's JS before reading the canonical tag (client-side canonical is a known weaker signal than server-rendered).
- Everything from `MEENSHA_HANDOFF_2026-09-13.md`'s "Known gaps" still
  applies (staging/production separation proposal awaiting review, AU
  Instagram Business account setup, kiosk WhatsApp-share flow still needing
  one real human tap-through test, Artisans blog draft needing a real
  anchor, two SEO keyword-naming calls).
- The keyword command-palette's greeting detection (`isGreeting` in
  `_shared/menuSearch.ts`) is an exact-match set after trim/lowercase —
  "hi!" or "hi there" won't match, only bare "hi"/"hello"/etc. Cosmetic,
  not fixed this session.
- `startAddPhoto`/`startAddPhotoAu` (deep-link entry point) doesn't
  currently distinguish "SKU not found" from "SKU exists but isn't
  available in this bot's region" in its user-facing message as precisely
  as the picker path does — minor, flagged by QA as a nit, not a real risk
  since the only two callers (the picker itself, and the health-check
  digest) never produce an out-of-region id today.

## Continued, later same day: full SEO audit + fixes shipped (commits f01e764, c5ea425)

**Installed the claude-seo toolkit** (`~/.claude/skills/seo*`, runtime needs Python 3.12 via `CLAUDE_SEO_PYTHON` in `~/.claude/settings.json` env). Ran `/seo audit https://meensha.in`: **47/100**. Reports are in `Meensha/meensha.in-audit/` (FULL-AUDIT-REPORT.md, ACTION-PLAN.md, MEASUREMENT.md, QA screenshots in qa/).

**Shipped to production (QA'd on test2 staging first; QA subagent found no FAILs or regressions):**
- 15 static `/sarees/<weave>/` pages plus `/sarees/` index, with a server-rendered title, H1, canonical, weave copy and BreadcrumbList schema, and a live product grid (`sarees/weave.js`). Generated by `setup/build_weave_pages.py`, which also writes sitemap.xml (18 URLs with lastmod; the `?shop=` and register.html entries are gone).
- `product.html?id=<sku uuid>`: per-product page with JS-injected Product/Offer schema. Add to Cart goes to the existing `./?buy=` flow. Homepage product cards link to it.
- Homepage: one H1 (sr-only; the slide quotes are now `<p>` and look identical), a keyword title, og-image.jpg (cropped from weaver_woman.png with the Gemini watermark cropped out), contactPoint schema, Event schema only when `popups.date_from` is set, preconnects, and a "Shop by weave" link row.
- Weight: GIF logo → animated WebP (2.5 MB → 372 KB); hero PNGs → WebP (3.8 MB → 600 KB); about.html base64 portraits → `founder_*.webp`. **Re-encoded the 54 product photos in Supabase storage in place (same keys, 404 MB → 17 MB); originals backed up to `Meensha/backups/item-photos-originals-2026-09-27/`.** admin.html upload compression 1600 → 1200px. It deliberately stays JPEG because the Telegram bots send these URLs via sendPhoto.
- **Enforce HTTPS enabled** on GitHub Pages via the API. http:// used to serve a 200 duplicate.
- Fixed pre-existing about.html bugs: `page_views` fetch ran before `const _SB`, a TDZ error that killed the rest of the script (so about views were never counted and the ticker never loaded). Also fixed a 21px horizontal overflow on desktop, and a 4px overflow on the homepage at 768px.

**Results (lab):** homepage 30.5 MB → 3.3 MB, LCP 22.7 → 9.5 s; about 5.2 MB → 1.2 MB, LCP 15.2 → 6.8 s.
**Heads-up for metrics:** about-page `page_views` will now show real numbers for the first time. A few views came from this session's automated render checks.

**Open / needs owners:** font trimming (main remaining LCP cost), Merchant Center, SKU descriptions (all empty), weaver stories, `popups.date_from`, anon key can read `inventory_skus.cost`, and SKU name typos ("Kalamakari", "Mangalgri") that hide items from the weave pages. After this deploy, resubmit the sitemap in GSC. Drift baselines were captured for /, /sarees/kalamkari/ and /about.html (`/seo drift compare <url>`).

**Gitea:** the `gitea` remote's raw LAN IP address didn't work with the TLS cert, so fetch/push failed until the push used the proper internal hostname instead. That's how it was pushed this session, and all three remotes are at 779d942. (Separately, a pre-existing credential-hygiene gap involving this remote was found and fixed in a later session — see the 09-28 handoff.)

## Working conventions (still apply, reconfirmed this session)

- Independent QA subagent before shipping caught a real bug this session
  that would not have been caught by type-checking or the build session's
  own read-through — worth continuing to use for any feature touching a
  live data column, not just as a formality.
- Always `git fetch` + diff before pushing to any remote right now — the
  autonomous cloud routine runs on its own schedule and can push to `test2`
  (and sometimes `origin`) between your own pushes. A rejected push is
  normal, not an error to force past.
- SQL migrations still need the user to run them manually in the Supabase
  SQL editor; copying the exact file to clipboard via `pbcopy` avoids
  paste-mangling seen earlier this project.
- Type-check edge functions locally before deploying (no Deno binary
  available in this environment): `npm install typescript@5` in a scratch
  dir, then `tsc --noEmit --target es2020 --module esnext --moduleResolution
  node --skipLibCheck <file>`, filtering out expected `Cannot find name
  'Deno'` / module-resolution noise.
