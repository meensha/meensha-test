// Daily tech-stack health digest, posted to MeenshaMonitor (@meenshabot).
// Reuses the same tech_health lookup the bot's natural-language Q&A uses
// (see _shared/knowledgeBase.ts) — one source of truth for what "healthy"
// means, whether triggered on a schedule or by someone asking "is the site
// up" directly. Meant to be called once a day by a pg_cron job (see
// setup/add_daily_health_check_cron.sql) — not triggered by user traffic.
//
// Required secrets: TELEGRAM_MONITOR_BOT_TOKEN, RAZORPAY_KEY_ID,
// RAZORPAY_KEY_SECRET (already set for create-payment-link).
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runLookup } from "../_shared/knowledgeBase.ts";

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const report = await runLookup(supabase, "tech_health", {});
  const anyIssue = report.includes("🔴") || report.includes("⚠️");
  const text = `${anyIssue ? "⚠️ Meensha Daily Health Check" : "✅ Meensha Daily Health Check — all clear"}\n\n${report}`;

  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    const chatId = row?.value;
    if (monitorToken && chatId) {
      await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatId, text }),
      });
    }
  } catch { /* best-effort — the check result still returns below either way */ }

  return new Response(JSON.stringify({ report }), { headers: { "Content-Type": "application/json" } });
});
