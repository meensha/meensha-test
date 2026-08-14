# Meensha Auth Security — Handoff to Continuation Chat

**Date found:** 2026-07-16. **CORRECTED 2026-07-16 (same day): the originally-reported critical leak was already fixed. See below.**

## Original finding (based on stale info) — since corrected
Initial investigation (grepping `schema_combined.sql`) found no RLS policy on `users` and a `doLogin()` that appeared to compare `password_hash=eq.<raw password>` directly — live-tested read access confirmed `users` was queryable via the anon key, and concluded passwords were likely plaintext and exposed. **This was based on `schema_combined.sql`, which is stale** — a later migration not reflected in that combined file already fixed this properly.

## Corrected status: already fixed, verified via git history and current code
Commit `a6e1dc2` ("Fix plaintext admin credentials leaked via anon key + hardcoded JS fallback", 2026-07-17) did the real fix, confirmed by reading `setup/move_password_hash_to_own_table.sql` in full and the actual current `admin.html`:

1. **`password_hash` was dropped from `users` entirely** and moved to a new table `user_credentials(user_id, password_hash)`.
2. **`user_credentials` has RLS enabled with zero policies for anon/authenticated** — in Postgres this means default-deny, i.e. the anon key gets literally zero rows from this table, not "restricted" access — none. Only `SECURITY DEFINER` functions (which bypass RLS as the function owner) can touch it.
3. **Real bcrypt hashing**, via `pgcrypto`'s `crypt()`/`gen_salt('bf')`, applied automatically on write via a trigger (`hash_password_trigger`).
4. **`login(username, password)` RPC** does the actual check server-side (`ph = crypt(p_password, ph)`) and returns only non-sensitive user info on success — the hash never reaches the browser.
5. **Current `admin.html`'s `doLogin()`** (verified directly, lines ~1216-1268) calls this RPC via `POST ${SB}/rest/v1/rpc/login` — it does **not** query `users.password_hash` directly (that column doesn't exist anymore). The comment in the code even says explicitly: "Password check happens server-side via the login() RPC — the hash never reaches the browser, and this is the only source of truth (no local fallback with hardcoded credentials anymore)."

**Bottom line: the credential exposure this doc originally reported does not exist in the current codebase.** Apologies for the alarm — should have checked for newer patch files before treating `schema_combined.sql` as current.

## Real, smaller bug found in the same investigation (still open, not fixed)
Two other functions in `admin.html` still write to `users.password_hash` — a column the migration dropped:
- `submitRecoveryCode()` (~line 2650): `sbUpd('users', ..., {password_hash: np, ...})`
- `submitEmailTokenReset()` (~line 2673): same pattern

These calls target a column that no longer exists post-migration. They were apparently never updated to call the migration's own `set_user_password(user_id, new_password)` RPC (which exists specifically for this — writes to `user_credentials` correctly, with auto-hashing via the same trigger). **Likely effect**: the recovery-code and email-link password-reset flows are silently broken (PostgREST would reject the unknown-column update; the app is noted elsewhere in the code as swallowing errors while still showing success toasts, so a user going through "forgot password" via either of these two paths may see a false "success" message while their password was never actually changed).

**Suggested fix** (small, targeted): change both call sites from `sbUpd('users', ..., {password_hash: np, ...})` to call `set_user_password(user_id, np)` instead (plus whatever other fields — `last_password_change`, `password_updated_via`, `must_change_password` — still belong on `users` and can stay as a normal `sbUpd('users', ...)` call without `password_hash`).

## Whether to still pursue the full Supabase Auth migration
This was discussed as a possible **future** hardening step, independent of the (already-fixed) leak: real Supabase Auth sessions + RLS enforced via `auth.uid()` on every table the admin panel touches, replacing the current pattern (anon key + UI-level gating, SECURITY DEFINER RPCs for the sensitive bits). That's a legitimately bigger, separate project — not urgent now that the actual leak is closed, but still architecturally the "more correct" long-term answer if this business's data ever needs stronger per-table access guarantees than "RPC-gate the sensitive stuff." Not scoped in detail here; revisit only if there's a concrete reason to prioritize it (e.g., adding more staff roles, handling more sensitive customer data, external audit requirement).

## Context: why this surfaced
Was investigating `admin.html`'s auth mechanism to decide whether a new popup-event POS tool should reuse it. That POS tool's design has since moved to a Telegram-bot approach in a different conversation thread, so this isn't blocking it either way.
