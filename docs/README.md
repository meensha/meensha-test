# Meensha — Documentation Index

**Start here:** [`MEENSHA_HANDOFF_2026-08-16.md`](MEENSHA_HANDOFF_2026-08-16.md) — today's addendum (read this first), then [`MEENSHA_HANDOFF_2026-08-15.md`](MEENSHA_HANDOFF_2026-08-15.md) for the fuller current-state doc it builds on.

| Doc | What it covers |
|---|---|
| `MEENSHA_HANDOFF_2026-08-16.md` | ⭐ Latest — Telegram bot Q&A, MeenshaMonitor auto-registration, a live bug found+fixed — read first |
| `MEENSHA_HANDOFF_2026-08-15.md` | Fuller current-state doc — customer auth, coupons, nav redesign, MeenshaMonitor wiring |
| `MEENSHA_HANDOFF_2026-08-11.md` | Earlier handoff snapshot — superseded, kept for history |
| `BLOG_DRAFT_building_meensha.md` | Notes/beats for a future blog post on building this stack — not publish-ready prose |
| `TELEGRAM_BOT_BUILD_PLAN.md` | India Telegram bot detailed spec/build plan |
| `MEENSHA_AUTH_SECURITY_HANDOFF.md` | Password/auth security investigation + fix confirmation |
| `PRICE_TAG_PRINT_REDESIGN.md` | Approved price-tag printing redesign |
| `MEENSHA_MONITORING.md` | Original monitoring/uptime + AI daily-summary architecture plan — mostly superseded by the simpler pg_cron + MeenshaMonitor approach actually built 2026-08-15 |
| `MASTER_PLAN_2026-07-12.md` | Original approved master plan — historical snapshot, superseded by the handoff doc |
| `Project Brief v3.md`, `initial_plan.md` | Earliest planning docs, kept for history |

**Not included here (local-only, never committed anywhere):** `.gitea-credentials`, `meensha_bots_creds.md`, `meensha-monitor-credentials.md` — all contain live credentials/tokens and stay on the local machine only.

**Correction (2026-08-15):** this folder was originally meant to be Gitea-only, but since `main` gets pushed identically to `test2`/`origin`/`gitea`, `docs/` has been present on all three since it was added — not actually Gitea-exclusive. Harmless (no credentials live here), just noting the claim below is no longer accurate. Gitea (`meensha-ecom`) remains the intended complete source of truth: full code history + all planning/handoff documentation together, same content as the other two repos.
