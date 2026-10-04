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
supabase/functions/_shared/
  chatbotClient.ts   -- askChatbot()/escalateChatbot(), used by both bots
supabase/migrations/
  20261004050000_verify_admin_session_for_chatbot.sql
```

Also touched outside `chatbot/`: `admin.html` (new `openChatbot()` + button),
`supabase/functions/telegram-bot/index.ts` and `telegram-bot-au/index.ts` (new
`maint:howworks` menu item, `howworks_ask`/`howworks_awaiting_escalate` session states,
`howworks:escalate:yes|no` callbacks).

## Before this works at all: apply the migration, and set two secrets

`supabase/migrations/20261004050000_verify_admin_session_for_chatbot.sql` has **not** been
applied to the live database — per this session's established convention (every migration
this session touched was applied manually), the file was created but not run. Apply it via
the Supabase SQL editor for project `eglanmhhcccsuhbxywua` before the admin.html path works
end-to-end. Until then, `auth.js`'s RPC call fails closed (the function doesn't exist yet) —
the safe failure mode, not a crash.

For the bot path, generate a `CHATBOT_API_SECRET` value once and set it in **two** places so
both sides agree on it:
- As a Supabase Edge Function secret: `supabase secrets set CHATBOT_API_SECRET=<value>`
  (read by `chatbotClient.ts` via `Deno.env.get`).
- As an env var on whatever host runs `chatbot/server/index.js` (read via
  `process.env.CHATBOT_API_SECRET` in `config.js`).

Also set `CHATBOT_BACKEND_URL` (the two bots' side — e.g.
`https://chatbot.meensha.in`) as a Supabase Edge Function secret once the VM exists. Until
all three of these are set, the bot path fails closed with a plain "chatbot isn't available
yet" message (see `askChatbot`/`escalateChatbot` in `chatbotClient.ts`) — never a crash,
never a silently-wrong answer.

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

## Deploying (Phase 5 — not done in this pass, Dheeraj's own step)

This needs a cloud account Claude Code cannot provision. Summary of what the plan calls
for, so a future session (or Dheeraj directly) can pick this up:

1. Provision an Oracle Cloud **Always-Free**-eligible VM (`VM.Standard.E2.1.Micro` or an
   Ampere A1 Always-Free allocation — confirm the "Always Free eligible" badge at creation,
   the console can default to a paid shape).
2. Copy the `chatbot/` directory to the VM. Install Node (no other dependencies).
3. Set `OPENROUTER_API_KEY` and `CHATBOT_API_SECRET` as environment variables on the VM
   (don't commit them).
4. Run `node chatbot/server/index.js` under a `systemd` unit (simpler than pm2, restarts on
   crash/reboot) — no unit file is included in this pass since it's host-specific.
5. Point `chatbot.meensha.in` (CNAME, domain already owned) at the VM, and put **Caddy** in
   front as a reverse proxy for zero-config free Let's Encrypt HTTPS. Caddy config is not
   included here — it's two lines (`chatbot.meensha.in { reverse_proxy localhost:8787 }`)
   once Caddy is installed on the VM.
6. Set `CHATBOT_BACKEND_URL=https://chatbot.meensha.in` and the same `CHATBOT_API_SECRET`
   value as Supabase Edge Function secrets (`supabase secrets set ...`) so both bots can
   reach the VM. Update `CHATBOT_URL` in admin.html if the actual hostname differs.
7. Re-verify `ESCALATION_MODEL` in `chatbot/server/config.js` is still a real, currently-free
   model on `https://openrouter.ai/models` (filter: free) — the catalog rotates. See the
   comment directly above that constant.
8. Re-run the Phase 1 red-flag grep across `chatbot/kb/` (see `chatbot/kb/CURATION_NOTES.md`)
   before every deploy, not just once.
9. Decide the owner-vs-sales tier question for the bots (see "Known gap" above) before
   relying on bot answers being tier-appropriate for anyone but kiosk staff.

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
