// Server-to-server client for the internal "how does this work" chatbot
// (chatbot/server/index.js, a separate standalone app — see chatbot/README.md).
// Used by both Telegram bots' "❓ How does this work?" flow.
//
// The chatbot has no login of its own for bot callers: each bot has already
// decided the caller's KB tier itself (see resolveChatbotTier in each bot's
// index.ts) before calling this, and authenticates that claim with a shared
// secret instead of a per-user token — the bot is stating a tier it already
// trusts, not asking the chatbot to re-derive identity.
//
// CHATBOT_BACKEND_URL / CHATBOT_API_SECRET are Supabase Edge Function
// secrets (set via `supabase secrets set`), not committed here and not yet
// set as of this writing — there is no deployed VM yet (chatbot/ Phase 5 is
// still outstanding). Until both are set, every call below fails closed
// (returns null / an error object), which callers surface as a plain
// "not available yet" message rather than crashing the bot flow.

export type ChatbotMatch = { source: string; heading: string | null; text: string; score: number };
export type ChatbotSearchResult = { confident: boolean; matches: ChatbotMatch[] };
export type ChatbotEscalateResult = { ok: true; answer: string; model: string } | { ok: false; error: string };

function configured(): boolean {
  return !!(Deno.env.get("CHATBOT_BACKEND_URL") && Deno.env.get("CHATBOT_API_SECRET"));
}

function authHeaders(tier: string) {
  return {
    "Content-Type": "application/json",
    "x-chatbot-secret": Deno.env.get("CHATBOT_API_SECRET") ?? "",
    "x-chatbot-tier": tier,
  };
}

// Returns null if the chatbot isn't configured/reachable — never throws,
// so a bot flow can fall back to a plain "not available" message.
export async function askChatbot(question: string, tier: string): Promise<ChatbotSearchResult | null> {
  if (!configured()) return null;
  try {
    const res = await fetch(`${Deno.env.get("CHATBOT_BACKEND_URL")}/api/search`, {
      method: "POST",
      headers: authHeaders(tier),
      body: JSON.stringify({ question }),
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

// Only ever called from the bot's explicit "ask external AI anyway" button
// flow (see howworks_awaiting_escalate_confirm in each bot) — never fired
// automatically after a no-confident-match search, same rule as the web UI.
export async function escalateChatbot(
  question: string,
  weakSnippet: string | undefined,
  tier: string,
): Promise<ChatbotEscalateResult> {
  if (!configured()) return { ok: false, error: "Chatbot escalation is not configured yet." };
  try {
    const res = await fetch(`${Deno.env.get("CHATBOT_BACKEND_URL")}/api/escalate`, {
      method: "POST",
      headers: authHeaders(tier),
      body: JSON.stringify({ question, weakSnippet }),
    });
    const body = await res.json();
    if (!res.ok || !body.ok) return { ok: false, error: body?.error || `HTTP ${res.status}` };
    return body;
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}
