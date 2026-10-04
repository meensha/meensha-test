// Opt-in external LLM escalation (Phase 3). Ported from chatbot/server/escalate.js.
// Only ever called from the /api/escalate route, which only ever fires on an
// explicit user button click in the frontend — never automatically from a
// failed local search.
//
// What gets sent to OpenRouter: the question, plus at most the single best
// already-curated weak-match snippet retrieval.ts found (if any) — never raw
// KB files, never a tier above the caller's own role.
//
// Logging: the original Node server appended one line per escalation to a
// local escalation-log.jsonl file. Edge Functions have no persistent
// filesystem across invocations, so this logs via console.log instead —
// visible with `supabase functions logs chatbot` — rather than pretending to
// write a file that won't survive the next cold start.

import { ESCALATION_MODEL, OPENROUTER_API_KEY } from "./config.ts";

export type EscalateResult = { ok: true; answer: string; model: string } | { ok: false; error: string };

function buildPrompt(question: string, weakSnippet?: string): string {
  let prompt = `You are answering an internal question about how a small e-commerce business's website and Telegram bots work. `;
  if (weakSnippet) {
    prompt += `Here is a possibly-related (but not confidently matching) excerpt from the internal docs:\n\n"""\n${weakSnippet}\n"""\n\n`;
  }
  prompt += `Question: ${question}\n\nAnswer concisely and plainly. If you don't know, say so rather than guessing.`;
  return prompt;
}

function logEscalation(question: string, model: string) {
  console.log(JSON.stringify({ event: "chatbot_escalation", ts: new Date().toISOString(), question, model }));
}

// Returns { ok: true, answer } or { ok: false, error }. Never throws.
export async function escalate(question: string, weakSnippet?: string): Promise<EscalateResult> {
  if (!question || !question.trim()) {
    return { ok: false, error: "No question provided." };
  }
  if (!OPENROUTER_API_KEY) {
    return { ok: false, error: "Escalation is not configured on this server (missing OPENROUTER_API_KEY)." };
  }

  logEscalation(question, ESCALATION_MODEL);

  let res: Response;
  try {
    res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${OPENROUTER_API_KEY}`,
      },
      body: JSON.stringify({
        model: ESCALATION_MODEL,
        messages: [{ role: "user", content: buildPrompt(question, weakSnippet) }],
      }),
    });
  } catch (e) {
    return { ok: false, error: `Could not reach OpenRouter: ${e instanceof Error ? e.message : String(e)}` };
  }

  if (!res.ok) {
    return { ok: false, error: `OpenRouter error: ${res.status}` };
  }

  let data: { choices?: { message?: { content?: string } }[] };
  try {
    data = await res.json();
  } catch {
    return { ok: false, error: "OpenRouter returned an unparseable response." };
  }

  const answer = data?.choices?.[0]?.message?.content?.trim();
  if (!answer) {
    return { ok: false, error: "OpenRouter returned no answer." };
  }

  return { ok: true, answer, model: ESCALATION_MODEL };
}
