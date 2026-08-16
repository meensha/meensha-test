// Clarify-then-answer flow for the natural-language Q&A feature.
// Uses Gemini (already trusted in this stack — same free-tier model
// admin.html uses for AI price suggestions), read fresh from
// settings.gemini_key on every call (same convention as everything else
// in this project that reads live config rather than baking in a secret).
//
// Design: the LLM is NEVER given database access or asked to write SQL. It
// only ever sees a fixed list of named, parameterized lookups (see
// knowledgeBase.ts) and picks one — or asks a clarifying question first if
// the request doesn't map cleanly onto any of them. Only the small, already-
// retrieved result of that one lookup gets sent back to Gemini for phrasing
// — never the raw database, never more than what's needed to answer this
// one question.

// deno-lint-ignore no-explicit-any
type SB = any;
import type { LookupDef, LookupName } from "./knowledgeBase.ts";

async function callGemini(apiKey: string, prompt: string): Promise<string> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }),
  });
  if (!res.ok) throw new Error(`Gemini error: ${res.status}`);
  const data = await res.json();
  return data?.candidates?.[0]?.content?.parts?.[0]?.text?.trim() || "";
}

export async function askGemini(
  supabase: SB,
  question: string,
  catalog: LookupDef[],
  runLookup: (supabase: SB, name: LookupName, params: Record<string, string>) => Promise<string>,
): Promise<string> {
  const { data: keyRow } = await supabase.from("settings").select("value").eq("key", "gemini_key").maybeSingle();
  const apiKey = keyRow?.value;
  if (!apiKey) return "AI lookup isn't configured yet (no Gemini key set in admin).";

  const catalogText = catalog.map((l) => `- ${l.name}: ${l.description}. Params: ${JSON.stringify(l.params)}`).join("\n");
  const routePrompt = `You are a lookup router for a saree e-commerce business's staff Telegram bot. A staff member asked a question. You have access to these lookups ONLY — you cannot answer from general knowledge, you cannot make up numbers:

${catalogText}

Question: "${question}"

Reply with ONLY one JSON object, no markdown, no explanation:
- If the question clearly maps to one lookup: {"action":"lookup","name":"<lookup name>","params":{...}}
- If it's too vague to pick params confidently (e.g. period or item unclear): {"action":"clarify","question":"<one short clarifying question>"}
- If it's not something any of these lookups can answer at all: {"action":"decline","reason":"<why>"}`;

  let routed: { action: string; name?: string; params?: Record<string, string>; question?: string; reason?: string };
  try {
    const raw = await callGemini(apiKey, routePrompt);
    const jsonText = raw.replace(/^```json\s*|```\s*$/g, "").trim();
    routed = JSON.parse(jsonText);
  } catch {
    return "Sorry, couldn't understand that — try asking more simply, e.g. \"ajrak stock\" or \"sales this week\".";
  }

  if (routed.action === "clarify") return routed.question || "Could you clarify what you mean?";
  if (routed.action === "decline") return routed.reason || "I can only answer stock, sales, and site-health questions.";
  if (routed.action !== "lookup" || !routed.name) return "Sorry, couldn't process that.";

  const lookupResult = await runLookup(supabase, routed.name as LookupName, routed.params || {});

  const phrasePrompt = `A staff member asked: "${question}"\n\nHere is the real data (from the live database) to answer it with:\n${lookupResult}\n\nReply with a short, plain, friendly answer using ONLY the data above — don't invent anything not shown. Keep it to 2-4 lines, no markdown formatting.`;
  try {
    return await callGemini(apiKey, phrasePrompt);
  } catch {
    return lookupResult; // fall back to the raw data if the phrasing call fails
  }
}
