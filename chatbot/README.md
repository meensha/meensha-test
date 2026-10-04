# Meensha Internal Chatbot — "How Does This Work?"

An internal-only tool so Dheeraj, Shalini, and Meenakshi can ask plain-language questions
about how the Meensha site/bots actually work and get grounded answers from a curated,
role-scoped knowledge base — with diagrams where that helps. Not customer-facing, and
entirely separate from the Supabase/GitHub Pages stack this repo otherwise builds.

See `/Users/dheerajbharti/.claude/plans/also-after-this-i-noble-marble.md` for the original
design rationale. **Note: Phase 4/7 of that plan text describe a standalone login form —**
**that was corrected mid-build (2026-10-04) and superseded by the design below.** This
README reflects what's actually here.

## No login of its own — reached from three existing surfaces

The chatbot never asks anyone to log in a second time. It's reachable from:

1. **admin.html** (Dheeraj/`super_admin`, and anyone else who logs into admin.html) — a new
   "🤖 Ask Chatbot" button next to the existing "❓ Help Guide" button opens
   `chatbot/frontend/index.html` in a new tab, passing the already-logged-in `CU.session_token`
   via a URL **fragment** (`#session_token=...`, never a query string — a fragment is never
   sent to any server or written to a request log, unlike `?session_token=...`). See
   `openChatbot()` in admin.html (next to `openHelpGuide()`).
2. **India bot** (`supabase/functions/telegram-bot/index.ts`) — a new "❓ How does this work?"
   menu item (Maintenance menu + keyword search) calls the chatbot server-to-server.
3. **AU bot** (`supabase/functions/telegram-bot-au/index.ts`) — same thing.

`chatbot/frontend/index.html` has no username/password form. If it's opened without a
`#session_token=...` fragment, it just says so and stops — there is no fallback login.

## Two ways the backend resolves a caller's KB tier

`chatbot/server/auth.js` (`resolveKbTierFromHeaders`) accepts either:

- **`x-admin-session`** — a real Supabase session token (the admin.html path above).
  Verified via the new `verify_admin_session_for_chatbot` RPC (migration below — **file
  only, not applied to the live DB**), which maps `super_admin`→`admin`, `owner`→`owner`,
  `sales`→`sales`.
- **`x-chatbot-secret` + `x-chatbot-tier`** — server-to-server only, used by the two bots.
  Authenticated by a shared secret (`CHATBOT_API_SECRET`, a Supabase Edge Function secret —
  **not generated/set yet**, since there's no VM to share it with) instead of a per-user
  token; the bot states the tier directly, it has already decided it before calling. Never
  exposed to an end user — no browser ever sends this header.

A secret presented at all but wrong fails closed (doesn't fall through to the session
path) — see the comment in `auth.js`.

## Resolved: both bots used to default every caller to `sales` tier

`telegram_allowed_users` / `telegram_allowed_users_au` used to have **no column
distinguishing the account owner (Shalini/Meenakshi) from any other allowlisted chat_id** —
just `chat_id`/`label`/`active`. An insertion-order heuristic ("first row = owner") was
considered and deliberately rejected during build: it's not a reliable signal, and getting
it wrong would leak owner-tier (financial/strategic) KB content to kiosk/sales staff — the
exact thing this feature's role-scoping exists to prevent.

Fixed via `supabase/migrations/20261004060000_chatbot_tier_role_column.sql` (migration file
only — needs manual application via the Supabase SQL editor, same as every other migration
this session, **not yet applied live**), which adds a `role text NOT NULL DEFAULT 'sales'
CHECK (role IN ('owner','sales'))` column to both tables and promotes the identified owner
row(s):

- `telegram_allowed_users` (India): chat_id `8853893414` (label "migrated", the only row on
  this table) → `role='owner'` — Shalini's account.
- `telegram_allowed_users_au` (Australia): chat_id `8918326830` (label "Meenakshi Ranjan") →
  `role='owner'` — Meenakshi's own account. The other AU row, chat_id `8853893414` (label
  "Meensha Fabrics" — the same chat_id promoted above, a shared/business-wide contact used
  for cross-bot broadcasts, not a second AU owner identity), stays at the `'sales'` default.

Both bots' `resolveChatbotTier(supabase, chatId)` / `resolveChatbotTierAu(supabase, chatId)`
now look up the caller's own row (`chat_id` + `active=true`) and read `role` — fails safe to
`'sales'` on any lookup miss (row not found, query error, or an unexpected `role` value),
never defaults to `'owner'`.

## File structure

```
chatbot/
  kb/{admin,owner,sales}/*.md   -- curated docs (Phase 1/1.5, already done before this pass)
  server/
    index.js        -- HTTP server: static frontend + /api/search + /api/escalate
    retrieval.js     -- loads kb/<role>/*.md, chunks by ## heading, scores
    synonyms.json    -- hand-maintained paraphrase map
    escalate.js       -- OpenRouter call (ESCALATION_MODEL), safe-snippet prompt build
    auth.js          -- resolves x-admin-session OR x-chatbot-secret+x-chatbot-tier
    config.js        -- Supabase URL/anon key, role->tier map, ESCALATION_MODEL, port, secret
    escalation-log.jsonl  -- created at runtime; one line per escalation (question+model)
  frontend/
    index.html, app.js, vendor/mermaid.min.js   -- no login UI; token via URL fragment only
  README.md          -- this file
supabase/functions/chatbot/   -- the DEPLOYED version (see "Deploying" below) — ported
  index.ts, auth.ts, retrieval.ts,   from the files above to Deno/Edge Function conventions.
  escalate.ts, config.ts,            chatbot/server/*.js and chatbot/frontend/* above are
  frontend.ts, kb_data.ts,           kept as reference/local-dev copies but are NOT what's
  synonyms_data.ts                   running live.
supabase/functions/_shared/
  chatbotClient.ts   -- askChatbot()/escalateChatbot(), used by both bots
supabase/migrations/
  20261004050000_verify_admin_session_for_chatbot.sql
```

Also touched outside `chatbot/`: `admin.html` (new `openChatbot()` + button),
`supabase/functions/telegram-bot/index.ts` and `telegram-bot-au/index.ts` (new
`maint:howworks` menu item, `howworks_ask`/`howworks_awaiting_escalate` session states,
`howworks:escalate:yes|no` callbacks).

## Status as of 2026-10-04: bot path live, admin.html path blocked on one migration

**Update:** this is now deployed as a Supabase Edge Function (see "Deploying" below), not a
VM. `CHATBOT_API_SECRET` and `CHATBOT_BACKEND_URL` are both set as Edge Function secrets —
the bot path (both Telegram bots' "❓ How does this work?" menu item) is fully live.

`supabase/migrations/20261004050000_verify_admin_session_for_chatbot.sql` is still **not**
applied to the live database — per this session's established convention (every migration
this session touched was applied manually), the file was created but not run. Apply it via
the Supabase SQL editor for project `eglanmhhcccsuhbxywua` before the **admin.html path**
(the "🤖 Ask Chatbot" button) works end-to-end. Until then, `auth.ts`'s RPC call fails closed
(the function doesn't exist yet) — verified via curl, returns a plain 401 "Invalid or
expired session," not a crash.

`OPENROUTER_API_KEY` is not set, so `/api/escalate` fails closed with a plain error message
until it's set via `supabase secrets set OPENROUTER_API_KEY=sk-or-...` — `/api/search` (the
main path for both the bots and admin.html, once the migration is applied) works fully
without it.

## Running it locally

```
cd chatbot/server
OPENROUTER_API_KEY=sk-or-... CHATBOT_API_SECRET=... PORT=8787 node index.js
```

`OPENROUTER_API_KEY` is only needed for the escalation path (`/api/escalate`) to actually
reach OpenRouter — local search works without it. `CHATBOT_API_SECRET` is only needed to
test the bot-style server-to-server auth path locally (e.g. with curl sending
`x-chatbot-secret`/`x-chatbot-tier` headers) — the admin.html path doesn't need it. No `npm
install` needed: no runtime dependencies beyond the vendored `mermaid.min.js`, Node's
built-in `http`/`fs` modules cover everything else. Needs a reasonably recent Node (built
and tested against Node 25; anything with built-in global `fetch`, i.e. Node 18+, should
work).

The frontend itself only renders usefully with a real `#session_token=...` fragment from a
real admin.html login — there's no standalone way to exercise it without that (by design).

## Deploying (Phase 5 — superseded: deployed as a Supabase Edge Function, not an Oracle VM)

**Oracle Cloud signup is blocked for the owner right now, so the original Oracle VM +
Caddy plan below was dropped (2026-10-04) in favor of reusing this repo's existing Edge
Function deploy pattern** (same as `telegram-bot`, `telegram-bot-au`, `daily-health-check`,
`razorpay-webhook`, etc.). **`chatbot/server/*.js` and `chatbot/frontend/*` (this directory)
are now superseded by `supabase/functions/chatbot/`** — kept in the repo as the readable,
Node-flavored reference implementation (and because `chatbot/kb/` is still the source of
truth the Edge Function's `kb_data.ts` is generated from), but they are **not what's
running**. Don't edit `chatbot/server/index.js` expecting it to affect the live chatbot —
edit `supabase/functions/chatbot/` instead.

### What's actually deployed

`supabase/functions/chatbot/` — same three responsibilities, ported to Deno/Edge Function
conventions (`createClient`-style secrets via `Deno.env.get`, `Deno.serve`):

- `index.ts` — routes `GET /` (frontend), `POST /api/search`, `POST /api/escalate`; strips
  the gateway's path prefix (observed as `/chatbot/...` in production, not
  `/functions/v1/chatbot/...` — `routeOf()` handles both forms).
- `auth.ts` — port of `chatbot/server/auth.js`'s `resolveKbTierFromHeaders`.
- `retrieval.ts` — port of `chatbot/server/retrieval.js`'s chunk/score logic, reading from
  `kb_data.ts` instead of the filesystem.
- `escalate.ts` — port of `chatbot/server/escalate.js`. One behavior change: Edge Functions
  have no persistent filesystem across invocations, so escalations are logged via
  `console.log` (visible with the Supabase dashboard's function logs) instead of appending
  to a local `escalation-log.jsonl` file.
- `config.ts` — same constants as `chatbot/server/config.js`, read from `Deno.env`.
- `frontend.ts` — the original `chatbot/frontend/index.html` + `app.js`, inlined as one HTML
  string this function serves on `GET /`. One difference: mermaid is loaded from
  `cdnjs.cloudflare.com` (already used elsewhere in this repo, e.g. `admin.html`) instead of
  the ~3.5MB vendored `mermaid.min.js` — simpler than bundling that file into the function.
- `kb_data.ts` — **auto-generated** from `chatbot/kb/{admin,owner,sales}/*.md`. Edge
  Functions don't reliably support reading arbitrary sibling files from the deployed bundle
  at runtime, so KB content is inlined as JSON-escaped string constants instead. **Whenever
  a KB markdown file is added/changed, regenerate this file before redeploying**:
  ```
  python3 -c "
  import json, os
  kb_root, tiers = 'chatbot/kb', ['admin', 'owner', 'sales']
  data = {t: {f: open(os.path.join(kb_root, t, f), encoding='utf-8').read()
              for f in sorted(os.listdir(os.path.join(kb_root, t))) if f.endswith('.md')}
          for t in tiers}
  with open('supabase/functions/chatbot/kb_data.ts', 'w', encoding='utf-8') as out:
      out.write('export const KB_DATA: Record<string, Record<string, string>> = ')
      out.write(json.dumps(data, ensure_ascii=False, indent=2))
      out.write(';\n')
  "
  ```
  then `supabase functions deploy chatbot --no-verify-jwt`.
- `synonyms_data.ts` — copy of `chatbot/server/synonyms.json`; keep in sync by hand.

### Deployed URL and secrets (set 2026-10-04)

- Function URL: `https://eglanmhhcccsuhbxywua.supabase.co/functions/v1/chatbot`
- Deployed with `supabase functions deploy chatbot --no-verify-jwt` (required for every
  function in this project — this function does its own auth via `auth.ts` instead of a
  Supabase user JWT).
- `CHATBOT_API_SECRET` — generated this session (`openssl rand -hex 32`) and set via
  `supabase secrets set`. Shared with the bots' side via the same name (read by
  `chatbotClient.ts`).
- `CHATBOT_BACKEND_URL` — set to the function URL above, as a Supabase Edge Function secret,
  so `chatbotClient.ts`'s `askChatbot`/`escalateChatbot` (used by both bots) can reach it.
- `OPENROUTER_API_KEY` — **not set**. `/api/search` (the bots' and admin.html's main path)
  works fully without it; `/api/escalate` fails closed with a plain, non-crashing
  `"Escalation is not configured on this server (missing OPENROUTER_API_KEY)"` message until
  it's set via `supabase secrets set OPENROUTER_API_KEY=sk-or-...`.
- `admin.html`'s `CHATBOT_URL` constant now points at the function URL above (was
  `https://chatbot.meensha.in/`). `openChatbot()` itself is unchanged — still opens the URL
  in a new tab with `#session_token=...` appended as a fragment.

### Verified end-to-end (2026-10-04, via curl)

- `GET /` → 200, serves the frontend HTML.
- `POST /api/search` with no auth headers → 401 (fails closed).
- `POST /api/search` with a wrong `x-chatbot-secret` → 401 (fails closed, does not fall
  through to the session path — see `auth.ts`).
- `POST /api/search` with the real secret, `x-chatbot-tier: admin`, asking about coupon
  internals → 200, returned `coupon-voucher-lifecycle.md` (an admin-only KB file).
- The **same question**, same secret, `x-chatbot-tier: sales` → 200, returned only
  `kiosk-coupon-basics.md` (the sales-tier file) — **no admin-tier content leaked**. Confirms
  role-scoping holds.
- `x-chatbot-tier: owner` → 200, returned owner-tier content (`TELEGRAM_BOT_BUILD_PLAN.md`,
  handoff docs), distinct from both other tiers.
- `x-admin-session: <any token>` (the admin.html/browser path) → 401, because
  `verify_admin_session_for_chatbot` isn't applied to the live DB yet (expected — see next
  section). Fails closed with the same plain "Invalid or expired session" message, not a
  crash.
- `POST /api/escalate` with a valid secret/tier but no `OPENROUTER_API_KEY` set → 502,
  `{"ok":false,"error":"Escalation is not configured on this server..."}` — fails closed as
  designed.

### What's still blocked on the pending migration

`supabase/migrations/20261004050000_verify_admin_session_for_chatbot.sql` is **still not
applied** to the live DB (unchanged from before this pass — same "file only, Dheeraj applies
manually" convention as every other migration this session). Until it's applied:

- The `x-admin-session` path — i.e. **the "🤖 Ask Chatbot" button inside admin.html** — fails
  closed with "Invalid or expired session," even for a real, valid admin.html login. This is
  expected and correct, not a bug.
- The **bot path** (both Telegram bots' "❓ How does this work?" menu item, via
  `chatbotClient.ts`) does **not** depend on this migration and is fully live now that
  `CHATBOT_API_SECRET`/`CHATBOT_BACKEND_URL` are set.

Apply the migration via the Supabase SQL editor for project `eglanmhhcccsuhbxywua` to
unblock the admin.html path — no further code changes needed once it's applied.

### Re-verify before every future redeploy

1. `ESCALATION_MODEL` in `supabase/functions/chatbot/config.ts` — re-checked 2026-10-04
   directly against `https://openrouter.ai/api/v1/models` (filtered for `:free`-suffixed
   ids): `qwen/qwen3.8-27b:free` is present with $0 pricing. The catalog rotates — re-check
   before relying on it.
2. Re-run the Phase 1 red-flag grep across `chatbot/kb/` (see `CURATION_NOTES.md`) before
   adding any new doc, same as always.
3. If `chatbot/kb/` changes, regenerate `kb_data.ts` (see above) before redeploying — the
   Edge Function has no other way to pick up new KB content.

## Adding a new KB doc

Follow `chatbot/kb/CURATION_NOTES.md` — human-reviewed, redaction is a judgment call. Drop
the `.md` file into `kb/admin/`, `kb/owner/`, or `kb/sales/`; `retrieval.js` reads the
directory fresh on every request, so no restart or index rebuild is needed.

## How retrieval works (Phase 2)

Local lexical search, no embeddings/vector DB — the corpus is a few dozen markdown files.
Each file is split into chunks by `##` heading; a query's terms (lowercased, stopwords
stripped, expanded via `synonyms.json`) are scored against each chunk's heading (weighted
3x) and body (1x), plus a flat boost for an exact-phrase substring match. Fewer than 2
matched terms on the best chunk means "no confident local match" — the matched chunk(s) are
always returned verbatim with their source filename; nothing is generated locally.

## How escalation works (Phase 3)

Only ever triggered by an explicit button/tap — "Ask an external AI instead" in the web
view, or the inline-keyboard "🤖 Yes, ask external AI" button in either bot — after a "no
confident match" response, never automatic. Sends the question plus, if one exists, the
single best already-curated weak-match snippet (never a raw KB file, never a tier above the
caller's own role) to OpenRouter using `ESCALATION_MODEL` (a free-tier model, see
`config.js`). Every escalation is appended to `chatbot/server/escalation-log.jsonl`
(question + model only, not the full response) so Dheeraj can see how often it fires —
useful signal for what to add to the local KB.

## Auth (Phase 4, corrected)

See "No login of its own" and "Two ways the backend resolves a caller's KB tier" above.
Whichever path resolves the tier, it happens **before** `retrieval.js` loads any KB files
for that request — a lower-tier caller's request never causes a higher-tier folder to be
read.
