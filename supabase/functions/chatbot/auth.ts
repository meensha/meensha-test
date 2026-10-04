// Resolves the caller's KB tier. Ported from chatbot/server/auth.js —
// same two paths, same fail-closed rules. See that file's comments for the
// full rationale; kept here in condensed form.
//
// (a) `x-admin-session` — a real session_token, forwarded by admin.html.
//     Verified against verify_admin_session_for_chatbot (supabase/migrations/
//     20261004050000_verify_admin_session_for_chatbot.sql — NOT yet applied
//     to the live DB as of this deploy; see chatbot/README.md). Until it's
//     applied, the RPC call 404s/errors and this path fails closed (returns
//     null), same as a bad token — never a crash.
// (b) `x-chatbot-secret` + `x-chatbot-tier` — server-to-server only, used by
//     the two Telegram bots via supabase/functions/_shared/chatbotClient.ts.

import { SUPABASE_URL, SUPABASE_ANON_KEY, ROLE_TO_KB_TIER, CHATBOT_API_SECRET, VALID_KB_TIERS } from "./config.ts";

// Returns the KB tier string ('admin'|'owner'|'sales') for a valid session,
// or null if the token is missing/invalid/expired/unmapped/RPC unavailable.
// Never guesses a default tier — null means "reject the request".
async function resolveKbTier(sessionToken: string | null): Promise<string | null> {
  if (!sessionToken) return null;

  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/verify_admin_session_for_chatbot`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_token: sessionToken }),
    });
  } catch {
    return null; // network/DB unreachable — fail closed
  }

  // The RPC raises (admin_session_invalid) for a bad/expired token, and a
  // non-existent RPC (migration not applied yet) also surfaces as a non-2xx
  // PostgREST response — both cases fail closed the same way.
  if (!res.ok) return null;

  let body: { role?: string };
  try {
    body = await res.json();
  } catch {
    return null;
  }

  const role = body && body.role;
  return (role && ROLE_TO_KB_TIER[role]) || null;
}

// Entry point used by index.ts: tries the bot server-to-server path first
// (cheap, no network call), falls back to the session-token RPC path.
export async function resolveKbTierFromHeaders(headers: Headers): Promise<string | null> {
  const secret = headers.get("x-chatbot-secret");
  if (secret) {
    // A secret was presented at all — treat this as a bot call and don't
    // fall through to the session path even if the secret is wrong, so a
    // typo'd secret fails closed rather than silently trying anonymous auth.
    if (!CHATBOT_API_SECRET || secret !== CHATBOT_API_SECRET) return null;
    const tier = headers.get("x-chatbot-tier") ?? "";
    return VALID_KB_TIERS.has(tier) ? tier : null;
  }
  return resolveKbTier(headers.get("x-admin-session"));
}
