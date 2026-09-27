// Daily tech-stack health digest, posted to MeenshaMonitor (@meenshabot),
// the India bot's staff chat (Shalini), AND the AU bot's staff chats
// (Meenakshi) — the missing-photos section used to skip Meenakshi entirely
// even though it already included AU-available items she's responsible for.
// Reuses the same tech_health lookup the bot's natural-language Q&A uses
// (see _shared/knowledgeBase.ts) — one source of truth for what "healthy"
// means, whether triggered on a schedule or by someone asking "is the site
// up" directly. Meant to be called once a day by a pg_cron job (see
// setup/add_daily_health_check_cron.sql) — not triggered by user traffic.
//
// Required secrets: TELEGRAM_MONITOR_BOT_TOKEN, TELEGRAM_BOT_TOKEN,
// TELEGRAM_BOT_TOKEN_AU, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET (already set
// for create-payment-link). Supabase auto-provides SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runLookup } from "../_shared/knowledgeBase.ts";

type Sku = { id: string; name: string; display_variant?: string; sku_code: string; photos?: string[]; india_available?: boolean; au_available?: boolean };

// Each pending item gets a tappable Telegram deep link straight into that
// bot's "add photo to item" flow (t.me/<bot>?start=photo_<sku_id>) instead
// of just naming the item in plain text — see maint:addphoto in both bots.
function photoLines(list: Sku[], botUsername: string): string {
  const shown = list.slice(0, 10).map((s) => {
    const label = `${s.name}${s.display_variant ? " (" + s.display_variant + ")" : ""}`;
    return `• ${label} — https://t.me/${botUsername}?start=photo_${s.id}`;
  }).join("\n");
  return shown + (list.length > 10 ? `\n+${list.length - 10} more` : "");
}

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
  const { data: allSkus } = await supabase
    .from("inventory_skus")
    .select("id, name, display_variant, sku_code, photos, india_available, au_available")
    .or("india_available.eq.true,au_available.eq.true");
  const missingPhotos = ((allSkus ?? []) as Sku[]).filter((s) => !s.photos || s.photos.length === 0);
  const missingIndia = missingPhotos.filter((s) => s.india_available);
  const missingAu = missingPhotos.filter((s) => s.au_available);

  const overviewLine = missingPhotos.length
    ? `📷 ${missingPhotos.length} item(s) with no photo (${missingIndia.length} India, ${missingAu.length} AU)`
    : "📷 Every item has at least one photo ✅";

  const anyIssue = report.includes("🔴") || report.includes("⚠️") || missingPhotos.length > 0;
  const heading = anyIssue ? "📋 Meensha Daily Health Check" : "✅ Meensha Daily Health Check — all clear";

  const monitorText = `${heading}\n\n${report}\n\n${overviewLine}\n\n👀 ${visits}`;
  const indiaText = `${heading}\n\n${report}\n\n${
    missingIndia.length
      ? `📷 ${missingIndia.length} item(s) with no photo (tap to fix):\n${photoLines(missingIndia, "meenshashalbot")}`
      : "📷 Every India item has at least one photo ✅"
  }\n\n👀 ${visits}`;
  const auText = `${heading}\n\n${
    missingAu.length
      ? `📷 ${missingAu.length} item(s) with no photo (tap to fix):\n${photoLines(missingAu, "meenshaozbot")}`
      : "📷 Every AU item has at least one photo ✅"
  }`;

  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    const chatId = row?.value;
    if (monitorToken && chatId) {
      await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: chatId, text: monitorText }),
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
          body: JSON.stringify({ chat_id: r.chat_id, text: indiaText }),
        });
      }
    }
  } catch { /* best-effort */ }

  try {
    const botTokenAu = Deno.env.get("TELEGRAM_BOT_TOKEN_AU");
    const { data: allowedRowsAu } = await supabase.from("telegram_allowed_users_au").select("chat_id").eq("active", true);
    if (botTokenAu) {
      for (const r of allowedRowsAu ?? []) {
        await fetch(`https://api.telegram.org/bot${botTokenAu}/sendMessage`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chat_id: r.chat_id, text: auText }),
        });
      }
    }
  } catch { /* best-effort */ }

  return new Response(JSON.stringify({ report, missing_photos: missingPhotos.length, missing_india: missingIndia.length, missing_au: missingAu.length }), { headers: { "Content-Type": "application/json" } });
});
