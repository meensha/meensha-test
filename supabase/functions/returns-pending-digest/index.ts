// Daily 10am IST digest of faulty items pending return to a vendor.
// Same pattern as daily-health-check (reuse the shared lookup, best-effort
// Telegram send, triggered by pg_cron — see setup/add_returns_pending_digest_cron.sql),
// but a different audience: this goes to India staff (telegram-bot, every
// active chat_id) as well as MeenshaMonitor, not just the owner — Shalini is
// the one who'd actually act on returning something to a vendor.
//
// Required secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_MONITOR_BOT_TOKEN.
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runLookup } from "../_shared/knowledgeBase.ts";

async function sendTo(token: string, chatId: string, text: string) {
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
  } catch { /* best-effort — one failed send must not block the others */ }
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const report = await runLookup(supabase, "returns_pending", {});
  const nothingPending = report.startsWith("No faulty items");
  const text = `${nothingPending ? "✅" : "🚨"} Returns Pending — Faulty Items\n\n${report}`;

  // Skip sending entirely when there's nothing pending — a daily "all clear"
  // ping isn't useful the way the health check's is (that one confirms the
  // whole stack is actually reachable; this one has nothing to confirm).
  if (nothingPending) {
    return new Response(JSON.stringify({ report, sent: false }), { headers: { "Content-Type": "application/json" } });
  }

  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");

  if (botToken) {
    const { data: allowedRows } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
    for (const row of allowedRows ?? []) {
      await sendTo(botToken, row.chat_id, text);
    }
  }
  if (monitorToken) {
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    if (row?.value) await sendTo(monitorToken, row.value, text);
  }

  return new Response(JSON.stringify({ report, sent: true }), { headers: { "Content-Type": "application/json" } });
});
