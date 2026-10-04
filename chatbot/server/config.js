// Chatbot server config.
//
// Separate, standalone app (not part of the Supabase functions tree), so it
// keeps its own small config file rather than reading repo-wide settings.

// Same Supabase project the rest of this repo uses (test2/origin share one
// backend). Anon key only — same public key already embedded in admin.html's
// own frontend source (line ~1183), safe to embed here for the same reason:
// it has no privileges on its own, every admin_* RPC checks a session token
// server-side.
const SUPABASE_URL = 'https://eglanmhhcccsuhbxywua.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVnbGFubWhoY2Njc3VoYnh5d3VhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ4Nzc2MDQsImV4cCI6MjA5MDQ1MzYwNH0.0qjzkMVVajqMkx7SM-hhd6J62zVVFduVDbdr6juiNgo';

// Maps the live `users.role` values onto this feature's three KB tiers (see
// chatbot/kb/CURATION_NOTES.md for what's in each tier). Deliberately NOT a
// 1:1 name match — super_admin is the fullest tier, named "admin" here.
const ROLE_TO_KB_TIER = {
  super_admin: 'admin',
  owner: 'owner',
  sales: 'sales',
};

const VALID_KB_TIERS = new Set(Object.values(ROLE_TO_KB_TIER));

// Shared secret for the server-to-server auth path (the two Telegram bots
// calling this API directly — see auth.js). Generated once and set as a
// Supabase Edge Function secret (`supabase secrets set CHATBOT_API_SECRET=...`)
// AND as this process's own env var — both sides read the same value, never
// committed here. Not set yet as of this writing (bots can't reach this API
// until it is); see chatbot/README.md.
const CHATBOT_API_SECRET = process.env.CHATBOT_API_SECRET || '';

// Escalation (Phase 3) only ever fires on an explicit user click — see
// escalate.js. This is a real, currently-free-tier OpenRouter model,
// deliberately separate from `settings.openrouter_model` in the existing
// bot code (supabase/functions/_shared/askGemini.ts), which defaults to the
// paid gpt-4o-mini. This feature must never inherit that.
//
// IMPORTANT — re-verify before every deploy: OpenRouter's free-model catalog
// rotates (models get added/removed/repriced). Checked 2026-10-04 against
// https://openrouter.ai/collections/free-models (and a cross-check against a
// second, independent listing of the same catalog) — qwen/qwen3.8-27b:free
// was listed with $0 prompt/completion pricing on both. Re-check the model id
// is still present and still $0 priced at https://openrouter.ai/models
// (filter: free) at each redeploy; if it's gone, pick another `:free`-suffixed
// chat-completion model from that page and update this constant.
const ESCALATION_MODEL = 'qwen/qwen3.8-27b:free';

// Where escalation logs (question + model, not full response) get appended.
const ESCALATION_LOG_PATH = require('path').join(__dirname, 'escalation-log.jsonl');

// Static frontend + port for the single Node process (index.js).
const PORT = process.env.PORT || 8787;
const FRONTEND_DIR = require('path').join(__dirname, '..', 'frontend');
const KB_DIR = require('path').join(__dirname, '..', 'kb');

module.exports = {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  ROLE_TO_KB_TIER,
  VALID_KB_TIERS,
  CHATBOT_API_SECRET,
  ESCALATION_MODEL,
  ESCALATION_LOG_PATH,
  PORT,
  FRONTEND_DIR,
  KB_DIR,
};
