// Meensha internal "how does this work?" chatbot, as a Supabase Edge
// Function. Ported from the standalone Node app in chatbot/server/ — see
// chatbot/README.md for the full design history. Originally planned to run
// on a separate Oracle Cloud VM; that's skipped (Oracle signup blocked for
// the owner) in favor of reusing this project's existing Edge Function
// deploy pattern (same as telegram-bot, telegram-bot-au, daily-health-check,
// razorpay-webhook, etc.).
//
// Three responsibilities, same as the original three files:
//   GET  /                -> serve the frontend (frontend.ts, inlined HTML/JS)
//   POST /api/search      -> role-scoped local retrieval (retrieval.ts)
//   POST /api/escalate    -> opt-in external LLM call (escalate.ts)
//
// Auth (auth.ts) resolves the caller's KB tier before any of the above runs,
// via either `x-admin-session` (admin.html's browser path) or
// `x-chatbot-secret`+`x-chatbot-tier` (the two bots' server-to-server path).
//
// Deploy with --no-verify-jwt (required for every function in this project,
// since this function does its own auth instead of relying on a Supabase
// user JWT).
//
// Required secrets: CHATBOT_API_SECRET (shared secret for the bot path).
// Optional: OPENROUTER_API_KEY (only needed for /api/escalate to actually
// reach OpenRouter — /api/search works without it). SUPABASE_URL and
// SUPABASE_ANON_KEY are auto-provided by Supabase.

import { resolveKbTierFromHeaders } from "./auth.ts";
import { search } from "./retrieval.ts";
import { escalate } from "./escalate.ts";
import { FRONTEND_HTML } from "./frontend.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-admin-session, x-chatbot-secret, x-chatbot-tier",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...CORS_HEADERS },
  });
}

function html(status: number, body: string): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", ...CORS_HEADERS },
  });
}

// Strips the function's own mount prefix so routing works the same whether
// this is reached as .../functions/v1/chatbot/api/search or, after a future
// custom-domain/rewrite, as .../api/search directly.
function routeOf(pathname: string): string {
  // The gateway passes different prefixes depending on how it's reached —
  // observed as "/chatbot/..." in production, but strip the fuller
  // "/functions/v1/chatbot/..." form too in case that ever shows up (e.g.
  // local `supabase functions serve`).
  const withoutFn = pathname.replace(/^\/functions\/v1\/chatbot/, "").replace(/^\/chatbot/, "");
  const trimmed = withoutFn.replace(/\/+$/, "");
  return trimmed === "" ? "/" : trimmed;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }

  const url = new URL(req.url);
  const route = routeOf(url.pathname);

  if (req.method === "POST" && route === "/api/search") {
    const tier = await resolveKbTierFromHeaders(req.headers);
    if (!tier) return json(401, { error: "Invalid or expired session." });

    let body: { question?: string } = {};
    try {
      body = await req.json();
    } catch {
      // treated as empty below
    }
    if (!body.question || !body.question.trim()) {
      return json(400, { error: "Missing question." });
    }
    return json(200, search(tier, body.question));
  }

  if (req.method === "POST" && route === "/api/escalate") {
    const tier = await resolveKbTierFromHeaders(req.headers);
    if (!tier) return json(401, { error: "Invalid or expired session." });

    // The frontend/bots only show the escalate option after an explicit
    // user click following an already-rendered "no confident match" state
    // — this route has no way to be reached except that explicit POST.
    let body: { question?: string; weakSnippet?: string } = {};
    try {
      body = await req.json();
    } catch {
      // treated as empty below
    }
    const result = await escalate(body.question ?? "", body.weakSnippet);
    return json(result.ok ? 200 : 502, result);
  }

  if (req.method === "GET" && route === "/") {
    return html(200, FRONTEND_HTML);
  }

  return json(404, { error: "Not found" });
});
