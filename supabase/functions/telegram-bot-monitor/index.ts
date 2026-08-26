// MeenshaMonitor (@meenshabot) — owner-facing bot. Previously push-only
// (sale-copy notifications from telegram-bot/telegram-bot-au, daily health
// digest from daily-health-check) with no interactive handler at all.
//
// This gives it two jobs:
//   1. Auto-register: the first message from any chat gets that chat_id
//      written to settings.telegram_monitor_chat_id — this is what the
//      other two features have been waiting on. No manual step needed
//      beyond messaging the bot once.
//   2. Natural-language knowledge-base Q&A, full scope (cross-region stock/
//      price/sales/P&L + on-demand tech-stack health) — see _shared/knowledgeBase.ts
//      for the safe, read-only lookup catalog and _shared/askGemini.ts for
//      the clarify-then-answer flow. The LLM never runs arbitrary SQL —
//      it only ever picks from a fixed set of parameterized lookups.
//
// Required secrets: TELEGRAM_MONITOR_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET_MONITOR.
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { runLookup, LOOKUP_CATALOG_FULL } from "../_shared/knowledgeBase.ts";
import { askGemini } from "../_shared/askGemini.ts";
import { handleRequestAction } from "../_shared/requestActions.ts";

const BOT_TOKEN = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN")!;
const TG_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

async function tgSend(chatId: number | string, text: string, keyboard?: unknown) {
  await fetch(`${TG_API}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, reply_markup: keyboard }),
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const secret = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
  if (secret !== Deno.env.get("TELEGRAM_WEBHOOK_SECRET_MONITOR")) {
    return new Response("Forbidden", { status: 403 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const update = await req.json();
  const msg = update.message ?? update.callback_query?.message;
  const chatId = msg?.chat?.id;
  const text: string | undefined = update.message?.text;
  const callbackData: string | undefined = update.callback_query?.data;
  if (!chatId) return new Response("ok", { status: 200 });

  // Auto-register: write this chat_id to settings the first time (or every
  // time — cheap upsert) a message arrives, so the sale-copy and daily
  // health-digest features (which read this same key) start working
  // without any separate manual step.
  const { data: existing } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
  const firstContact = !existing?.value;
  if (existing) {
    await supabase.from("settings").update({ value: String(chatId) }).eq("key", "telegram_monitor_chat_id");
  } else {
    await supabase.from("settings").insert({ key: "telegram_monitor_chat_id", value: String(chatId) });
  }

  if (firstContact) {
    await tgSend(chatId, "✅ Connected — I'll now send sale notifications and the daily health check here.\n\nYou can also just ask me things, e.g. \"how's Ajrak stock in India\", \"sales this week\", or \"is the site up\".");
    return new Response("ok", { status: 200 });
  }

  if (callbackData?.startsWith("req:")) {
    const actorFrom = update.callback_query?.from;
    const actor = "Owner (" + ([actorFrom?.first_name, actorFrom?.last_name].filter(Boolean).join(" ") || actorFrom?.username || "Monitor") + ")";
    await handleRequestAction(supabase, chatId, callbackData, actor, tgSend);
    await fetch(`${TG_API}/answerCallbackQuery`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id: update.callback_query.id }),
    });
    return new Response("ok", { status: 200 });
  }

  if (!text) return new Response("ok", { status: 200 });
  if (text === "/start") {
    await tgSend(chatId, "MeenshaMonitor is connected. Ask me anything about stock, sales, or site health.");
    return new Response("ok", { status: 200 });
  }

  try {
    const result = await askGemini(supabase, text, LOOKUP_CATALOG_FULL, runLookup);
    await tgSend(chatId, result);
  } catch (e) {
    await tgSend(chatId, "Sorry, couldn't process that — try rephrasing, or ask something simpler.");
    console.error(e);
  }

  return new Response("ok", { status: 200 });
});
