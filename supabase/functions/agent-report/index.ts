// Standing reporting endpoint for the recurring TODO-list cloud routine
// (see the routine created via /schedule — runs every 4 hours against
// meensha-test's test2 branch, working through TODO.md). Unlike this
// repo's various one-off send-*-message utilities (deployed, used once,
// deleted), this one is meant to stay deployed since the routine calls it
// on every run. Relays a plain-text status to both the India bot's staff
// chat and MeenshaMonitor.
//
// Deployed with the DEFAULT verify_jwt (true) — unlike Telegram/Razorpay
// webhooks, there's no external caller here that's unable to supply a
// Supabase JWT, so this isn't left fully public. The calling cloud agent
// is given only the public anon key (same key already embedded
// client-side in index.html/admin.html — not a secret) as its
// Authorization bearer, never a service-role credential.
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_MONITOR_BOT_TOKEN.
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const { text } = await req.json();
  if (!text) return new Response("text required", { status: 400 });

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const results: Record<string, boolean> = {};

  try {
    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const { data: allowedRows } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
    if (botToken) {
      for (const row of allowedRows ?? []) {
        const r = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chat_id: row.chat_id, text }),
        });
        results["shalini_" + row.chat_id] = r.ok;
      }
    }
  } catch { /* best-effort */ }

  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    if (monitorToken && row?.value) {
      const r = await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: row.value, text }),
      });
      results.monitor = r.ok;
    }
  } catch { /* best-effort */ }

  return new Response(JSON.stringify({ ok: true, results }), { headers: { "Content-Type": "application/json" } });
});
