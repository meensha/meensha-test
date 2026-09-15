// Daily tech-stack health digest, posted to MeenshaMonitor (@meenshabot)
// AND the India bot's staff chat (Shalini) — previously monitor-only.
// Reuses the same tech_health lookup the bot's natural-language Q&A uses
// (see _shared/knowledgeBase.ts) — one source of truth for what "healthy"
// means, whether triggered on a schedule or by someone asking "is the site
// up" directly. Meant to be called once a day by a pg_cron job (see
// setup/add_daily_health_check_cron.sql) — not triggered by user traffic.
//
// Required secrets: TELEGRAM_MONITOR_BOT_TOKEN, TELEGRAM_BOT_TOKEN,
// RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET (already set for
// create-payment-link). Supabase auto-provides SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runLookup } from "../_shared/knowledgeBase.ts";

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const [report, visits] = await Promise.all([
    runLookup(supabase, "tech_health", {}),
    runLookup(supabase, "visit_stats", {}),
  ]);

  // Items with stock but no photos at all can't sell well online (no image
  // in the shop grid) and look unfinished on a shared catalogue link — flag
  // them daily until someone adds a photo, same nagging-reminder spirit as
  // pending-cost-digest for AU purchase costs.
  const { data: noPhotoSkus } = await supabase
    .from("inventory_skus")
    .select("name, display_variant, sku_code, photos")
    .or("india_available.eq.true,au_available.eq.true");
  const missingPhotos = (noPhotoSkus ?? []).filter((s: { photos: unknown[] }) => !s.photos || s.photos.length === 0);
  const photosLine = missingPhotos.length
    ? `📷 ${missingPhotos.length} item(s) with no photo:\n${missingPhotos.slice(0, 10).map((s: { name: string; display_variant?: string }) => `• ${s.name}${s.display_variant ? ` (${s.display_variant})` : ""}`).join("\n")}${missingPhotos.length > 10 ? `\n+${missingPhotos.length - 10} more` : ""}`
    : "📷 Every item has at least one photo ✅";

  const anyIssue = report.includes("🔴") || report.includes("⚠️") || missingPhotos.length > 0;
  const text = `${anyIssue ? "📋 Meensha Daily Health Check" : "✅ Meensha Daily Health Check — all clear"}\n\n${report}\n\n${photosLine}\n\n👀 ${visits}`;

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

  try {
    const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
    const { data: allowedRows } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
    if (botToken) {
      for (const r of allowedRows ?? []) {
        await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chat_id: r.chat_id, text }),
        });
      }
    }
  } catch { /* best-effort */ }

  return new Response(JSON.stringify({ report, missing_photos: missingPhotos.length }), { headers: { "Content-Type": "application/json" } });
});
