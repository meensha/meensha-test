# Meensha — Documentation Index

**Start here:** [`MEENSHA_HANDOFF_2026-08-11.md`](MEENSHA_HANDOFF_2026-08-11.md) — the current living status doc. Everything else in this folder is a detail doc it references.

| Doc | What it covers |
|---|---|
| `MEENSHA_HANDOFF_2026-08-11.md` | ⭐ Current state, deployment status, feature inventory, known gaps — read first |
| `TELEGRAM_BOT_BUILD_PLAN.md` | India Telegram bot detailed spec/build plan |
| `MEENSHA_AUTH_SECURITY_HANDOFF.md` | Password/auth security investigation + fix confirmation |
| `PRICE_TAG_PRINT_REDESIGN.md` | Approved price-tag printing redesign |
| `MEENSHA_MONITORING.md` | Monitoring/uptime + AI daily-summary architecture, homelab/Gitea integration notes |
| `MASTER_PLAN_2026-07-12.md` | Original approved master plan — historical snapshot, superseded by the handoff doc |
| `Project Brief v3.md`, `initial_plan.md` | Earliest planning docs, kept for history |

**Not included here (local-only, never committed anywhere):** `.gitea-credentials`, `meensha_bots_creds.md`, `meensha-monitor-credentials.md` — all contain live credentials/tokens and stay on the local machine only.

This `docs/` folder is Gitea-only — it's deliberately not pushed to the GitHub repos (`test2`/`origin`), which stay focused on the deployable site files. Gitea (`meensha-ecom`) is the complete source of truth: full code history + all planning/handoff documentation together.
