// Admin-triggered (never cron/automatic): summarizes one Pop-Up Event's
// post-event notes (popup_notes) with an LLM and delivers the summary to
// (a) Telegram, by calling the already-deployed agent-report function, and
// (b) a new popup_note_summaries row, read by admin.html's "past events"
// list. See TODO/handoff notes for the "Analyze & Submit" button in
// admin.html that calls this.
//
// Auth: this function does NOT re-implement the x-admin-session check.
// Instead it forwards the caller's x-admin-session header to the
// popup_notes_list RPC (supabase/migrations/20261027240000_popup_prep_checklist.sql),
// which itself calls require_admin_session() — that one call does double
// duty as "is this session valid" and "fetch the notes". A bad/expired
// token makes that REST call fail (non-2xx), and this function returns 401
// without ever touching the LLM or Telegram. This was a deliberate choice
// over duplicating the session-hash lookup in TS (as chatbot/auth.ts does
// for its own, differently-shaped tier check) — one fewer place that has
// to agree with the SQL session logic.
//
// Required secrets: AGENT_REPORT_KEY (to call agent-report), plus whatever
// _shared/askGemini.ts's callLLM() already needs (settings.openrouter_key/
// gemini_key — no new secret for the LLM call itself). Supabase
// auto-provides SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callLLM } from "../_shared/askGemini.ts";

type Note = { id: string; note: string; written_by_name: string | null; created_at: string };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const sessionToken = req.headers.get("x-admin-session") ?? "";
  const { popup_id } = await req.json().catch(() => ({ popup_id: null }));
  if (!popup_id) return new Response("popup_id required", { status: 400 });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const restHeaders = {
    "Content-Type": "application/json",
    apikey: anonKey,
    Authorization: `Bearer ${anonKey}`,
    "x-admin-session": sessionToken,
  };

  // Gate + fetch in one call — see header comment above.
  const notesRes = await fetch(`${supabaseUrl}/rest/v1/rpc/popup_notes_list`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_popup_id: popup_id }),
  });
  if (!notesRes.ok) return new Response("Unauthorized", { status: 401 });
  const notes: Note[] = await notesRes.json();

  if (!notes.length) {
    return new Response(JSON.stringify({ ok: false, reason: "no_notes" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: popup } = await supabase.from("popups").select("title").eq("id", popup_id).maybeSingle();
  const eventTitle = popup?.title || "this Pop-Up Event";

  const notesText = notes
    .slice().reverse()
    .map((n) => `- (${n.written_by_name || "staff"}) ${n.note}`)
    .join("\n");
  const prompt = `These are post-event staff notes for a saree brand's pop-up stall event "${eventTitle}". Summarize them into a short, practical debrief (4-8 lines, no markdown): what went well, what to fix next time, and anything actionable for the next event of this kind. Use ONLY the notes below — don't invent anything.\n\n${notesText}`;

  let summary: string;
  try {
    summary = await callLLM(supabase, prompt);
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, reason: "llm_failed", error: String(e) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  await fetch(`${supabaseUrl}/rest/v1/rpc/popup_notes_save_summary`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_popup_id: popup_id, p_summary: summary }),
  });

  const agentKey = Deno.env.get("AGENT_REPORT_KEY");
  if (agentKey) {
    try {
      await fetch(`${supabaseUrl}/functions/v1/agent-report`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-agent-key": agentKey },
        body: JSON.stringify({ text: `📝 Pop-up debrief — ${eventTitle}\n\n${summary}` }),
      });
    } catch { /* best-effort — the summary is already saved either way */ }
  }

  return new Response(JSON.stringify({ ok: true, summary }), { headers: { "Content-Type": "application/json" } });
});
