# Staging/Production Separation — Proposal

Status: proposal only. Nothing in this document has been implemented. Today's
completed work (telegram-bot, log-auth-attempt, auth-log-digest Edge Functions,
and the new `auth_log` table) is treated as done and is not touched by this
proposal — it is the starting point for the migration plan below.

## 1. Current State

The repo maintains two git remotes (`origin` → `meensha-test`, deployed as the
production site at meensha.in via GitHub Pages with a `CNAME` file, and `test2`
→ `meensha-test2`, the staging site) and the team's workflow assumes these are
two independent environments. That's true for the **frontend only** — each
remote serves its own static HTML/JS from its own GitHub Pages site, with no
GitHub Actions workflow in either branch (`.github/` doesn't exist on `main`
or `test2/main`; Pages presumably serves the repo root directly on push). The
**backend is not separated at all**: `supabase/.temp/linked-project.json`
shows the Supabase CLI in this working copy is linked to a single project,
`eglanmhhcccsuhbxywua`, and there is no `supabase/config.toml` or any
per-branch project config — there's only one project to link to. Every
`supabase functions deploy` or migration `push` run from either branch's
checkout lands in that one live database and one live set of ~21 Edge
Functions (`supabase/functions/*`), regardless of which git branch prompted
it. So "push to staging, verify, promote to prod" only ever verified the
frontend; any backend change was already live in production the moment it
was deployed. Worth flagging separately: `supabase/migrations/` currently
totals 10 files, and the oldest one (`20260825115150_remote_schema.sql`) is
0 bytes — i.e., the bulk of the existing schema predates migration tracking
and lives only in the live database, not in git. That matters for any
mirroring plan (see below): replaying `supabase/migrations/` into a fresh
project would NOT reproduce today's real schema; a `supabase db dump` (or
equivalent) of the live database is needed as the actual seed.

## 2. Options

### (a) A second, fully separate Supabase project for `test2`

Create a brand-new Supabase project, link the `test2` branch/checkout to it,
seed it from a dump of production's current schema (not from
`supabase/migrations/`, per the gap noted above), and give it its own copy of
every secret (`TELEGRAM_BOT_TOKEN` for a second bot, `RAZORPAY_*` in test
mode, `SUPABASE_SERVICE_ROLE_KEY`, etc.).

- **Cost**: Supabase's exact current free-tier limits and organization
  project caps change over time — I'm not fully certain of today's numbers
  (historically Supabase has capped free projects per organization and
  auto-pauses inactive free projects after a period of no traffic), so this
  should be verified directly at supabase.com/pricing before committing. If a
  second free project isn't available or gets auto-paused, this option
  carries a real recurring cost (a paid-tier project).
- **Complexity**: highest of the three. Every Edge Function needs its own
  secret set; a second Telegram bot token is needed to avoid the staging bot
  colliding with the live bot's webhook/chat; Razorpay would need test-mode
  keys; the schema needs an initial dump-and-restore and then needs to be
  kept in sync as production evolves.
- **Workflow disruption**: after initial setup, this is the *least*
  disruptive going forward — it makes "push to test2, verify, promote"
  actually true end-to-end, matching what the team already believes is
  happening.

### (b) Supabase's built-in database branching

Supabase offers a "branching" feature (ephemeral/preview database branches
tied to a Git branch, with schema migrations applied automatically) — but
this is gated behind a paid plan tier, and the exact tier/pricing has changed
over Supabase's product history. I don't have current, verified confirmation
of what tier this business's project is on or whether branching is available
to it today — that needs to be checked directly in the Supabase dashboard
(Project Settings → this org's plan) before this option is treated as
real. If available, this is the most "correct" fix — Supabase-native,
minimal custom plumbing, migrations-driven — but it depends entirely on the
existing migrations being complete and accurate, and today they are not (see
the empty base-schema migration above). Branching would also apply the
Edge Functions/secrets question differently than a fully separate project;
that mechanism would need to be researched further before relying on it.

### (c) No structural change — discipline + labeling instead

Keep one Supabase project, but adopt an explicit convention: every Edge
Function and migration gets a marker (e.g. a comment header, or a
`SAFE_FOR_SHARED_BACKEND.md` / `NEEDS_ISOLATION.md` list) stating whether it
was verified safe to test directly against the shared/live backend (i.e., it
only reads, or writes to a clearly separate/new table with no blast radius
on orders, payments, or the bot) versus needing isolated testing before it
touches the shared database.

- **Cost**: $0, no new infrastructure.
- **Complexity**: lowest by far — it's a process change, not a technical one.
- **Workflow disruption**: minimal, but it doesn't fix the underlying
  problem — it just makes the risk visible and manual instead of invisible.
  It still relies on a human correctly judging "is this safe" every time,
  which is exactly the kind of judgment call that failed today (the team's
  mental model was "test2 is isolated" and it wasn't).

## 3. Recommendation

**Option (c) now, as an immediate stop-gap, with a deliberate path toward
option (a) — not (b) — as the real fix, done incrementally rather than as a
big-bang cutover.**

Reasoning: this is a small, live, single-operator business running real
Telegram orders and Razorpay payments. Option (b) is the "correct"
architecture on paper but depends on unverified assumptions (current plan
tier, whether branching's automatic migration-apply model interacts safely
with Edge Functions and secrets, and — most importantly — that the tracked
migrations reflect the real schema, which they currently do not). Chasing it
now risks time spent discovering it doesn't apply, or applying it against an
incomplete schema definition. Option (a) is the durable fix, but it has real
setup cost (a second bot token, test-mode payment keys, a full secret
mirror) that shouldn't be rushed while production is actively serving orders
today. Option (c) costs nothing, ships immediately, and directly targets the
exact failure mode that happened today — someone believing "this is safe
because it's on the test branch." Layering (c) in now buys time to build (a)
properly without leaving the gap unaddressed in the interim.

## 4. Migration Plan

Ordered so production is never at risk of downtime; nothing here reverts or
re-touches today's completed work.

1. **Immediate (today), no infra change**: Add a short note at the top of
   `supabase/functions/README` (or create one if none exists) and as a
   comment header convention for new functions/migrations, stating: "This
   project has ONE Supabase backend shared by both `origin` and `test2`.
   Any deploy here is live in production." This alone prevents a repeat of
   today's discovery being needed twice. (Option (c), step 1.)
2. **This week**: Produce a full inventory doc (or extend this one) listing
   every existing Edge Function and table with a safe/needs-isolation label,
   starting with the highest-risk surfaces first: `razorpay-webhook`,
   `create-payment-link`, `telegram-bot`, `telegram-bot-au`. Anything
   touching payments or the live bot gets "needs isolation" by default.
3. **Before starting option (a) setup**: Run a schema dump against the live
   project (`supabase db dump` or the dashboard's schema export) to capture
   the *actual* current schema — do not rely on `supabase/migrations/` alone,
   since the base schema migration is empty. Store this dump as the seed
   artifact for the new project (not committed if it contains sensitive
   data — treat as an operational artifact, reviewed for secrets before any
   storage).
4. **Provision the second project**: Create the new Supabase project
   (verifying current pricing/free-tier limits first, per the caveat in
   Option (a)). Restore the schema dump from step 3 into it. This step has
   zero effect on the live project — it's purely additive.
5. **Mirror secrets, with new values, not copies, where the secret is an
   external credential**: For anything that talks to a third party the new
   project needs its OWN test-mode credential, not a duplicate of
   production's:
   - `TELEGRAM_BOT_TOKEN` / `TELEGRAM_WEBHOOK_SECRET` → register a *second*,
     separate Telegram bot for staging use; never point staging at the
     production bot's token.
   - `RAZORPAY_*` → use Razorpay's test-mode keys, never live keys.
   - `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` → these change naturally
     since they're generated per-project.
   - Anything else discovered in the `Deno.env.get(...)` audit (email
     provider keys, Gemini API key referenced in `_shared/askGemini.ts`,
     etc.) gets its own key or a scoped/sandbox equivalent where the
     provider supports one.
6. **Replicate today's already-deployed work into the new project**:
   `telegram-bot`, `log-auth-attempt`, `auth-log-digest`, and the `auth_log`
   table need to be deployed/created in the new staging project too, using
   the new project's own secrets from step 5 — they are not moved or
   removed from production, they are copied so staging has parity. This is
   the one place today's work is "touched," and only additively (deploy
   into the new target, nothing changes in production).
7. **Re-point `test2`'s Supabase CLI link**: Update the `test2` branch's
   local/CI Supabase link (whatever replaces the current manual
   `supabase link` step, since there's no CI config today) to target the new
   project ref instead of `eglanmhhcccsuhbxywua`. Production (`origin`/`main`)
   keeps linking to the existing project — no change there.
8. **Verify in parallel, don't cut over abruptly**: For a short overlap
   period, treat both the label-based discipline from steps 1–2 AND the new
   isolated project as active — don't delete the "safe/needs-isolation"
   labeling process once the new project exists; keep it as a secondary
   safety net, since a new project only helps if people remember to
   deploy/test against it.
9. **Only after the new project has been used successfully for a few real
   deploy cycles**, consider formalizing CI (a GitHub Actions workflow per
   branch) so `test2` pushes automatically target the new project and
   `main` pushes automatically target production — removing the manual
   `supabase link` step as a source of human error. This is optional
   hardening, not required for the core fix.

## 5. What NOT To Do

- **Do not** attempt a "big bang" cutover where the new staging project is
  provisioned, secrets mirrored, and CI reconfigured all in one sitting
  under time pressure. Each step above should be independently verifiable
  before moving to the next; rushing risks a misconfigured secret or link
  silently pointing a future "test" deploy back at production.
- **Do not** reuse the *production* Telegram bot token, Razorpay live keys,
  or the production service-role key for the new staging project "just to
  get started faster." That recreates exactly today's problem in a new
  form — a nominal separation that isn't real.
- **Do not** try to reconstruct the schema for the new project purely from
  `supabase/migrations/`. The base schema migration is empty (0 bytes) —
  replaying migrations alone will produce an incomplete/wrong schema. Always
  seed from a live dump.
- **Do not** revert, delete, or "clean up" today's `auth_log` table or the
  three newly deployed functions in the live project as part of this
  transition. They are done; this plan only adds a mirrored copy elsewhere.
- **Do not** run schema migrations or Edge Function deploys against
  production as a way of "testing whether the new staging project works" —
  any verification of the new project's correctness should happen entirely
  within the new project, never by touching the shared one again.
- **Do not** let webhook URLs (Telegram, Razorpay) for the new staging
  bot/keys silently point at production Edge Function URLs, or vice versa —
  double-check every webhook registration explicitly names the correct
  project's function URL before going live with the new setup.

## 6. Git Repo / Remote Consolidation (Proposal Only — Nothing Deleted)

This section is a separate but related cleanup: there are more copies of
this codebase floating around than are actually needed. As with everything
above, this is read-only research — nothing below has been deleted or
modified.

### 6.1 Full inventory of what exists

**Remotes on the working `meensha-test` repo** (`git remote -v` inside
`/Users/dheerajbharti/Claude Projects/Meensha/meensha-test`):

| Remote | URL host/repo | Role |
|---|---|---|
| `origin` | `github.com/meensha/meensha-test.git` | Production — deploys meensha.in via GitHub Pages (`CNAME` file present) |
| `test2` | `github.com/meensha/meensha-test2.git` | Staging — separate GitHub Pages site |
| `gitea` | the LAN-only self-hosted address | Private self-hosted backup mirror — network-unreachable from this sandboxed session, described as push-manually-only |

Note: the credentials embedded in these remote URLs (GitHub PAT for
`origin`/`test2`, a password for `gitea`) are visible in plaintext in
`.git/config` — that's a separate, pre-existing hygiene issue worth flagging
on its own, but out of scope for this proposal to fix.

**Other locations under `/Users/dheerajbharti/Claude Projects/Meensha/`
that look like copies or backups of the codebase or its data:**

- `Build M1 M2/` — a standalone snapshot from **28 May 2026**: `admin.html`
  (236 KB, vs. today's 321 KB), `schema_auth.sql`, `edge-send-auth-email.ts`,
  `EDGE_SETUP.md`, `m1_m2.md`. Not a git repo — just loose files. Predates
  the current `supabase/migrations/` history entirely.
- `files-5/` — an even older snapshot from **6 May 2026**: `admin.html`,
  `schema.sql`, `schema_base.sql`, `schema_auth.sql`, `EDGE_SETUP.md`,
  `edge-send-auth-email.ts`. Also not a git repo.
- `Backup/` — contains **business data**, not code: `Meensha_Backup_2026-04-10.json`,
  an inventory `.xlsx`, a sales `.xlsx`, and a stock PDF, all dated
  10–11 April 2026.
- `backups/` (note: a second, similarly-named but distinct folder) — also
  **business data**, not code: an inventory `.xlsx` and two inventory-related
  JSON exports dated 18–19 July 2026, plus an unrelated poster PDF.
- `Others/` — marketing/brand assets (product photos, generated hero
  images, logos) plus one old standalone `index.html` (5 Apr 2026) and one
  old inventory `.xlsx`. Not a code backup in any meaningful sense.
- `supabase/.temp/` at the *top* `Meensha/` level (separate from
  `meensha-test/supabase/.temp/`) — just a leftover Supabase CLI link cache,
  not a code copy.

A repo-wide search confirmed **only one actual git repository exists** on
disk: `meensha-test/.git`. `Build M1 M2` and `files-5` are not git repos —
they're loose file dumps from earlier points in the project's history.

### 6.2 Redundant vs. genuinely distinct-purpose

- **Genuinely distinct, keep as active deploy targets (not backups):**
  `origin` (production) and `test2` (staging) are live deploy targets the
  team's workflow depends on today. These should **not** be folded into any
  "backup" count — they're infrastructure, not archives.
- **Serves a real, distinct purpose (a backup, but only one is needed):**
  `gitea` is the only thing that currently functions as an actual off-GitHub
  backup of the git history itself.
- **Redundant — stale snapshots of the codebase, superseded by
  `meensha-test`:** `Build M1 M2/` and `files-5/`. Both are older than the
  current repo's earliest migration and are missing everything built since
  May 2026 (payments, Telegram bot, returns handling, coupons, etc., all of
  which now live only in `meensha-test`). They serve no purpose that
  `meensha-test`'s git history (via `git log`) doesn't already cover better.
- **Not code redundancy at all — business data, different category:**
  `Backup/`, `backups/`, `Others/`. These aren't copies of the codebase, so
  they're outside the scope of "repo consolidation" as asked, but the two
  similarly-named `Backup/` and `backups/` folders are worth a human glance
  since the naming collision looks accidental rather than intentional.

### 6.3 Recommendation — exactly one backup, plus the two active deploy remotes

To land on exactly one backup copy (per your ask), while keeping the deploy
workflow intact:

**Keep:**
- `origin` remote (production deploy target — not a backup, stays)
- `test2` remote (staging deploy target — not a backup, stays)
- `gitea` remote, as **the one backup** — it's the only thing actually
  serving that role today (a full git-history mirror, off-GitHub). Confirm
  it's reachable and actually up to date from a non-sandboxed machine before
  relying on it (this session couldn't reach the LAN-only address to verify).

**Propose removing (pending your explicit sign-off — nothing touched):**
- `Build M1 M2/` (directory) — superseded snapshot, safe to delete once you
  confirm nothing in it (e.g. `edge-send-auth-email.ts`, `EDGE_SETUP.md`) is
  referenced from memory as "the only copy" of something not carried
  forward into `meensha-test`. A quick diff/read before deleting is prudent
  since these are hard to reverse.
- `files-5/` (directory) — same reasoning, older and more superseded than
  `Build M1 M2/`.

**Explicitly not part of this recommendation (different category, need a
separate decision from you):** `Backup/`, `backups/`, `Others/` — these hold
business data (inventory, sales, images), not code, and weren't asked about
in terms of code-repo consolidation. Flagging the `Backup/`/`backups/`
naming collision for your awareness, not proposing deletion of either.

### 6.4 What NOT to do here

- **Do not** delete `Build M1 M2/` or `files-5/` without first confirming
  `gitea` (the one kept backup) is actually reachable and current — you
  don't want zero working backups in the gap between deleting the old
  snapshots and verifying the real one.
- **Do not** delete any of `Backup/`, `backups/`, or `Others/` as part of
  this — they weren't part of the "repo" ask and hold data, not code.
- **Do not** remove the `origin` or `test2` git remotes — they are active
  deploy targets, not backups, regardless of how this consolidation is
  scoped.
