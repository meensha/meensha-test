// Builds and sends a "Request a Saree" notification (new-request alert or
// daily reminder) to the right region's staff bot allowlist AND
// MeenshaMonitor. Self-contained (own fetch calls, own tokens) so it can be
// called from notify-new-request and daily-request-reminders without
// importing a bot's Deno.serve entrypoint file.

// deno-lint-ignore no-explicit-any
type SB = any;

function requestButtons(id: string) {
  return {
    inline_keyboard: [[
      { text: "💬 Reply", callback_data: `req:reply:${id}` },
      { text: "✅ Done", callback_data: `req:done:${id}` },
      { text: "❌ Not Done", callback_data: `req:notdone:${id}` },
    ]],
  };
}

function requestMessage(req: Record<string, unknown>, heading: string): string {
  const badge = req.region === "australia" ? "🇦🇺" : req.region === "india" ? "🇮🇳" : "";
  const lines = [
    `${badge} ${heading}`,
    `${req.customer_name || "Customer"} — ${req.item_name || "(no item specified)"}${req.quantity ? ` (x${req.quantity})` : ""}`,
    req.notes ? `"${req.notes}"` : null,
    req.wa ? `WhatsApp: ${req.wa}` : null,
    req.instagram_handle ? `Instagram: @${req.instagram_handle}` : null,
    req.photo_url ? `Photo: ${req.photo_url}` : null,
  ].filter(Boolean);
  return lines.join("\n");
}

async function sendTo(token: string, chatId: string | number, text: string, keyboard: unknown) {
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, reply_markup: keyboard }),
    });
  } catch { /* best-effort per recipient */ }
}

export async function broadcastRequestNotification(supabase: SB, req: Record<string, unknown>, heading: string) {
  const text = requestMessage(req, heading);
  const keyboard = requestButtons(req.id as string);

  const regionToken = req.region === "australia" ? Deno.env.get("TELEGRAM_BOT_TOKEN_AU") : Deno.env.get("TELEGRAM_BOT_TOKEN");
  const allowlistTable = req.region === "australia" ? "telegram_allowed_users_au" : "telegram_allowed_users";
  if (regionToken) {
    const { data: rows } = await supabase.from(allowlistTable).select("chat_id").eq("active", true);
    for (const r of rows ?? []) await sendTo(regionToken, r.chat_id, text, keyboard);
  }

  const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
  if (monitorToken) {
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").maybeSingle();
    if (row?.value) await sendTo(monitorToken, row.value, text, keyboard);
  }
}
