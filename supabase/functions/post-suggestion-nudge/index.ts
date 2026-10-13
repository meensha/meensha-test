// Scheduled nudge enforcing the ~2x/week posting cadence from the social
// media growth plan (Stage 3) — without this, "Suggest a post" only ever
// fires if Shalini remembers to open the Maintenance menu herself. Runs via
// pg_cron (see setup/add_post_suggestion_nudge_cron.sql), reuses the exact
// same suggestPost() logic the interactive Maintenance-menu flow uses (see
// _shared/postSuggestion.ts) — a proactive push and a manually-triggered
// suggestion are the same code path, not two implementations that can
// drift apart. India-only by design — see feedback_social_media_notifications.md.
//
// Required secret: TELEGRAM_BOT_TOKEN (same as telegram-bot).
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { callLLM } from "../_shared/askGemini.ts";
import { suggestPost } from "../_shared/postSuggestion.ts";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const TG_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

async function tgSend(chatId: number, text: string, replyMarkup?: unknown) {
  await fetch(`${TG_API}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, reply_markup: replyMarkup }),
  });
}

Deno.serve(async (_req: Request) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Independent of whatever the chat is doing: the draft is stored aside (not
  // in her session) and she gets a one-tap "open" button, so a nudge can never
  // overwrite a half-finished flow (e.g. a kiosk cart). Sessions that sit
  // idle are closed separately by the meensha-session-autoclose cron.
  const { data: allowedRows } = await supabase.from("telegram_allowed_users").select("chat_id").eq("active", true);
  let sent = 0;
  for (const row of allowedRows ?? []) {
    const chatId = Number(row.chat_id);
    let drafted = false;
    const stashDraft = async (_sb: unknown, cid: number, _state: string, data: Record<string, unknown>) => {
      await supabase.from("settings").upsert({ key: `postsuggest_pending_${cid}`, value: JSON.stringify(data) }, { onConflict: "key" });
      drafted = true;
    };
    const teaser = async (cid: number, text: string, keyboard?: unknown) => {
      if (keyboard) {
        await tgSend(cid, "📣 Time for a new post — a suggestion is ready for you.", {
          inline_keyboard: [[{ text: "📣 Open today's suggestion", callback_data: "postsuggest:open" }]],
        });
      } else {
        await tgSend(cid, text);
      }
    };
    await suggestPost(supabase, chatId, callLLM, teaser, stashDraft);
    if (drafted) sent++;
  }

  return new Response(JSON.stringify({ nudged: sent, total: (allowedRows ?? []).length }), { headers: { "Content-Type": "application/json" } });
});
