// Resolves the caller's KB tier. Two ways in, per the corrected Phase 4
// design — the chatbot has no login form of its own, it is only ever
// reached via a session/identity that already exists elsewhere:
//
// (a) `x-admin-session` — a real session_token, forwarded as-is by
//     admin.html (which already has it in memory from its own login) via
//     the tiny web view this app serves. Verified against the new
//     verify_admin_session_for_chatbot RPC (supabase/migrations/
//     20261004050000_verify_admin_session_for_chatbot.sql — NOT yet applied
//     to the live DB as of this writing; see chatbot/README.md).
// (b) `x-chatbot-secret` + `x-chatbot-tier` — server-to-server only, used by
//     the two Telegram bots. A bot already knows who's asking (its own
//     allowlist check happens before any message is processed) and has
//     already mapped that to a KB tier itself; it just states the tier
//     here, authenticated by a shared secret instead of a per-user token.
//     Never exposed to an end user — no browser ever sends this header.
//
// Every /api/search and /api/escalate call goes through this first, so a
// lower-tier caller's request never even reaches retrieval.js with a
// higher-tier folder name — the role is resolved before anything else runs.

const { SUPABASE_URL, SUPABASE_ANON_KEY, ROLE_TO_KB_TIER, CHATBOT_API_SECRET, VALID_KB_TIERS } = require('./config');

// Returns the KB tier string ('admin'|'owner'|'sales') for a valid session,
// or null if the token is missing/invalid/expired/unmapped. Never guesses a
// default tier — null means "reject the request", not "fall back to sales".
async function resolveKbTier(sessionToken) {
  if (!sessionToken) return null;

  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/verify_admin_session_for_chatbot`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_token: sessionToken }),
    });
  } catch {
    return null; // network/DB unreachable — fail closed
  }

  // The RPC raises (admin_session_invalid) for a bad/expired token, which
  // PostgREST surfaces as a non-2xx response, not a JSON {role} body.
  if (!res.ok) return null;

  let body;
  try {
    body = await res.json();
  } catch {
    return null;
  }

  const role = body && body.role;
  return ROLE_TO_KB_TIER[role] || null;
}

// Entry point used by index.js: tries the bot server-to-server path first
// (cheap, no network call), falls back to the session-token RPC path.
// Returns the KB tier string or null — never a default/guessed tier.
async function resolveKbTierFromHeaders(headers) {
  const secret = headers['x-chatbot-secret'];
  if (secret) {
    // A secret was presented at all — treat this as a bot call and don't
    // fall through to the session path even if the secret is wrong, so a
    // typo'd secret fails closed rather than silently trying anonymous auth.
    if (!CHATBOT_API_SECRET || secret !== CHATBOT_API_SECRET) return null;
    const tier = headers['x-chatbot-tier'];
    return VALID_KB_TIERS.has(tier) ? tier : null;
  }
  return resolveKbTier(headers['x-admin-session']);
}

module.exports = { resolveKbTier, resolveKbTierFromHeaders };
