// Opt-in external LLM escalation (Phase 3). Only ever called from the
// /api/escalate route, which only ever fires on an explicit user button
// click in the frontend — never automatically from a failed local search.
//
// What gets sent to OpenRouter: the question, plus at most the single
// best already-curated weak-match snippet retrieval.js found (if any) —
// never raw KB files, never a tier above the caller's own role (the caller's
// resolved tier is what retrieval.js was already scoped to before this ran).
// Mirrors the existing askGemini.ts/knowledgeBase.ts boundary: the LLM only
// ever sees a pre-selected safe string, never open access.

const fs = require('fs');
const { ESCALATION_MODEL, ESCALATION_LOG_PATH } = require('./config');

const OPENROUTER_KEY = process.env.OPENROUTER_API_KEY || '';

function buildPrompt(question, weakSnippet) {
  let prompt = `You are answering an internal question about how a small e-commerce business's website and Telegram bots work. `;
  if (weakSnippet) {
    prompt += `Here is a possibly-related (but not confidently matching) excerpt from the internal docs:\n\n"""\n${weakSnippet}\n"""\n\n`;
  }
  prompt += `Question: ${question}\n\nAnswer concisely and plainly. If you don't know, say so rather than guessing.`;
  return prompt;
}

function logEscalation(question, model) {
  const line = JSON.stringify({ ts: new Date().toISOString(), question, model }) + '\n';
  try {
    fs.appendFileSync(ESCALATION_LOG_PATH, line);
  } catch {
    // Logging is best-effort — never block the actual escalation on it.
  }
}

// Returns { ok: true, answer } or { ok: false, error }. Never throws.
async function escalate(question, weakSnippet) {
  if (!question || !question.trim()) {
    return { ok: false, error: 'No question provided.' };
  }
  if (!OPENROUTER_KEY) {
    return { ok: false, error: 'Escalation is not configured on this server (missing OPENROUTER_API_KEY).' };
  }

  logEscalation(question, ESCALATION_MODEL);

  let res;
  try {
    res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${OPENROUTER_KEY}`,
      },
      body: JSON.stringify({
        model: ESCALATION_MODEL,
        messages: [{ role: 'user', content: buildPrompt(question, weakSnippet) }],
      }),
    });
  } catch (e) {
    return { ok: false, error: `Could not reach OpenRouter: ${e.message}` };
  }

  if (!res.ok) {
    return { ok: false, error: `OpenRouter error: ${res.status}` };
  }

  let data;
  try {
    data = await res.json();
  } catch {
    return { ok: false, error: 'OpenRouter returned an unparseable response.' };
  }

  const answer = data?.choices?.[0]?.message?.content?.trim();
  if (!answer) {
    return { ok: false, error: 'OpenRouter returned no answer.' };
  }

  return { ok: true, answer, model: ESCALATION_MODEL };
}

module.exports = { escalate, buildPrompt };
