// Chatbot Edge Function config. Ported from chatbot/server/config.js —
// same constants, read from Deno.env instead of process.env.

// Supabase auto-provides SUPABASE_URL and SUPABASE_ANON_KEY to every
// deployed Edge Function (same project the rest of this repo uses —
// test2/origin share one backend).
export const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
export const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// Maps the live `users.role` values onto this feature's three KB tiers (see
// chatbot/kb/CURATION_NOTES.md for what's in each tier). Deliberately NOT a
// 1:1 name match — super_admin is the fullest tier, named "admin" here.
export const ROLE_TO_KB_TIER: Record<string, string> = {
  super_admin: "admin",
  owner: "owner",
  sales: "sales",
};

export const VALID_KB_TIERS = new Set(Object.values(ROLE_TO_KB_TIER));

// Shared secret for the server-to-server auth path (the two Telegram bots
// calling this function directly via supabase/functions/_shared/chatbotClient.ts
// — see auth.ts). Set via `supabase secrets set CHATBOT_API_SECRET=...`.
export const CHATBOT_API_SECRET = Deno.env.get("CHATBOT_API_SECRET") ?? "";

// Escalation (Phase 3) only ever fires on an explicit user click — see
// escalate.ts. Re-verify before every deploy: OpenRouter's free-model
// catalog rotates. Checked 2026-10-04 directly against
// https://openrouter.ai/api/v1/models (filtered for ids ending ":free") —
// qwen/qwen3.8-27b:free was present with $0 pricing. Re-check at each
// redeploy; if it's gone, pick another ":free"-suffixed chat-completion
// model from https://openrouter.ai/models (filter: free) and update this.
export const ESCALATION_MODEL = "qwen/qwen3.8-27b:free";

// Needs to be set via `supabase secrets set OPENROUTER_API_KEY=sk-or-...`
// for /api/escalate to actually reach OpenRouter — local search (/api/search)
// works without it. Not set as of this deploy; see chatbot/README.md.
export const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY") ?? "";
