// Daily morning reminder (pg_cron, 08:30 IST) of the open social-media setup
// steps, sent to Shalini's bot as its own separate message with the action
// flow diagram, a clickable link per step, and a "Done" button per step.
// Stops on its own once every step in settings.social_actions is done.
// India-only by design — see feedback_social_media_notifications.md.
//
// Checklist lives in settings.social_actions as JSON:
//   [{ "id": "fb_page", "label": "...", "url": "...", "done": false }, ...]
// "Done" taps are handled by telegram-bot (callback socialact:done:<id>).
//
// ?monitor=1 also sends MeenshaMonitor a plain-text copy (used for the first send).
// Required secrets: TELEGRAM_BOT_TOKEN (+ TELEGRAM_MONITOR_BOT_TOKEN for ?monitor=1).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const DIAGRAM_URL = "https://eglanmhhcccsuhbxywua.supabase.co/storage/v1/object/public/item-photos/social/social_actions_flow.png";

type Item = { id: string; label: string; url?: string; done: boolean };

async function tg(token: string, method: string, body: Record<string, unknown>) {
  await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

Deno.serve(async (req: Request) => {
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const withMonitor = new URL(req.url).searchParams.get("monitor") === "1";

  const { data: row } = await supabase.from("settings").select("value").eq("key", "social_actions").maybeSingle();
  const items: Item[] = row?.value ? JSON.parse(row.value) : [];
  const pending = items.filter((i) => !i.done);
  if (!pending.length) {
    return new Response(JSON.stringify({ sent: 0, reason: items.length ? "all done" : "no checklist" }), { headers: { "Content-Type": "application/json" } });
  }

  const lines = pending.map((i, n) => `${n + 1}. ${i.label}${i.url ? `\n   ${i.url}` : ""}`);
  const text = `🌅 Social media — ${pending.length} step${pending.length > 1 ? "s" : ""} still to do\n\n${lines.join("\n")}\n\nTap ✅ below as you finish each one. This reminder comes every morning until all are done.`;
  const keyboard = { inline_keyboard: pending.map((i) => [{ text: `✅ Done: ${i.label.split(":")[0].slice(0, 40)}`, callback_data: `socialact:done:${i.id}` }]) };

  const token = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
  const { data: users } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
  let sent = 0;
  for (const u of users ?? []) {
    await tg(token, "sendPhoto", { chat_id: u.chat_id, photo: DIAGRAM_URL });
    await tg(token, "sendMessage", { chat_id: u.chat_id, text, reply_markup: keyboard, disable_web_page_preview: true });
    sent++;
  }

  if (withMonitor) {
    const mtoken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    const { data: m } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    if (mtoken && m?.value) {
      await tg(mtoken, "sendPhoto", { chat_id: m.value, photo: DIAGRAM_URL });
      await tg(mtoken, "sendMessage", { chat_id: m.value, text: `(Sent to Shalini — daily until done)\n\n${text}`, disable_web_page_preview: true });
    }
  }

  return new Response(JSON.stringify({ sent, pending: pending.length }), { headers: { "Content-Type": "application/json" } });
});
