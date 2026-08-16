# Meensha — Handoff Addendum (2026-08-16)

Builds on `MEENSHA_HANDOFF_2026-08-15.md` (still the fuller reference — customer auth, coupons, MeenshaMonitor wiring, nav redesign all covered there and still accurate). This doc only covers what changed today.

## New: natural-language knowledge-base Q&A, all three Telegram bots

Staff/owner can now type a plain-language question instead of only using the button menus. Architecture, deliberately conservative:

- **The LLM (Gemini) never runs SQL or gets raw database access.** It only ever picks from a small, fixed, named list of parameterized lookups (`_shared/knowledgeBase.ts`): `item_lookup`, `sales_summary`, `low_stock`, `tech_health`, `pnl_summary`. If the question is ambiguous it asks one clarifying question first; if it doesn't map to any lookup, it declines rather than guessing.
- Only the small result of that one lookup gets sent back to Gemini to phrase into a sentence — never the full database, never more than one question needs. Gemini's API is stateless per-request; nothing gets persisted on Google's side between calls. (This was an explicit requirement — keep critical business data out of any third-party "knowledge base," only pass the minimum per-query.)
- **India bot** (`telegram-bot`) and **AU bot** (`telegram-bot-au`): unrecognized free text, only when idle (not mid-sale or mid-Stock-Intake), routes here — scoped to their own region's stock/price/sales only.
- **MeenshaMonitor** (`telegram-bot-monitor`, new): full scope — cross-region lookups, P&L, and on-demand tech-stack health (`"is the site up?"`). This is MeenshaMonitor's first-ever interactive handler; it was push-only before today (sale-copy notifications, daily digest).

## MeenshaMonitor auto-registration — the chat_id blocker is finally resolved

Getting `@meenshabot`'s chat_id had been stuck for two sessions (Telegram's `getUpdates` polling kept coming back empty despite repeated user confirmation of messaging it — root cause never fully pinned down, possibly a stray earlier poll consuming updates before they could be read). Fixed properly this time: `telegram-bot-monitor` now runs behind a real webhook, and **auto-writes its own chat_id into `settings.telegram_monitor_chat_id` the instant it receives any message** — no manual capture step at all anymore. This also means the sale-copy notifications (from yesterday) and the daily health digest will start actually delivering the moment anyone messages the bot.

## `daily-health-check` now reports real stats, not just ✅/⚠️

Reuses the same `tech_health` lookup the Q&A feature uses (one source of truth). Now includes response times per check and live counts (SKU count, units in stock, active coupons), e.g.:

```
✅ Website (275ms)
✅ Supabase (724ms)
✅ Razorpay (864ms)
✅ GitHub+Pages (320ms)

📦 43 SKUs, 110 units in stock, 7 active coupon(s)
```

## Live bug found and fixed: AU bot was completely broken for several hours

**Root cause**: Supabase's Edge Function gateway now enforces JWT verification by default on new deploys. Telegram's webhook calls never send an `Authorization` header, so a function deployed without the `--no-verify-jwt` flag rejects every incoming Telegram message *before its own code ever runs* — no error visible anywhere except a 401 at the gateway.

**Impact**: `telegram-bot-au` was redeployed earlier in the 2026-08-15 session (for the self-service-allowlist feature) without that flag, and has been silently non-functional for Meenakshi/AU staff since — any sale attempt via the bot during that window would have gotten no response at all. `telegram-bot` (India) happened to predate this gateway default from an earlier deploy and was unaffected.

**Fix**: redeployed `telegram-bot-au` with `--no-verify-jwt`. Confirmed all Telegram-facing functions are now correctly configured via `supabase functions list`:

| Function | verify_jwt | Correct? |
|---|---|---|
| `telegram-bot` | false | ✅ (Telegram calls it directly, no auth header) |
| `telegram-bot-au` | false | ✅ fixed today |
| `telegram-bot-monitor` | false | ✅ new, deployed correctly from the start |
| `daily-health-check` | false | ✅ (pg_cron calls it with no auth header) |
| `create-payment-link`, `razorpay-webhook`, and the 4 customer-auth functions | true | ✅ correct — these are called from the browser with the anon key already attached |

**Lesson for future deploys**: any new Edge Function meant to be called *without* a Supabase anon/service key in the request (Telegram webhooks, cron jobs) needs `--no-verify-jwt` explicitly on every deploy, not just the first one — a plain redeploy can silently reset it.

## Reference

- `docs/MEENSHA_HANDOFF_2026-08-15.md` — fuller current-state doc, still the primary reference for everything else
- `supabase/functions/_shared/knowledgeBase.ts`, `_shared/askGemini.ts` — the Q&A implementation
- `supabase/functions/telegram-bot-monitor/index.ts` — MeenshaMonitor's new interactive handler
