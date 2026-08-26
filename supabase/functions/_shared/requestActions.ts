// Shared "Request a Saree" callback-button handling, used by all three bots
// (telegram-bot, telegram-bot-au, telegram-bot-monitor) so Shalini,
// Meenakshi, and the owner can all act on a request directly from
// whichever bot notified them — reply to the customer, or mark it
// Done/Not-Done — without needing admin.html.
//
// The "editable pre-filled message" requirement is satisfied via a
// WhatsApp deep link: the template text is pre-filled into the wa.me URL,
// and WhatsApp itself lets the sender edit it before hitting send — this
// avoids building a separate text-capture session flow in Telegram, which
// would be real added complexity for the same practical result. Instagram
// has no deep-link equivalent, so that path is copy-paste of the same
// template text.

// deno-lint-ignore no-explicit-any
type SB = any;
type SendFn = (chatId: number | string, text: string, keyboard?: unknown) => Promise<void>;

function buildTemplate(req: Record<string, unknown>): string {
  const name = (req.customer_name as string) || "there";
  const item = (req.item_name as string) || "the item you asked about";
  const qty = (req.quantity as number) || 1;
  return `Hi ${name}! Thanks for your interest in ${item}${qty > 1 ? ` (x${qty})` : ""}. ` +
    `We're checking on availability and will let you know as soon as we have an update. 🙏 — Meensha`;
}

export async function handleRequestAction(supabase: SB, chatId: number, callbackData: string, actor: string, tgSend: SendFn) {
  const [, action, id] = callbackData.split(":");
  const { data: reqRow } = await supabase.from("requests").select("*").eq("id", id).maybeSingle();
  if (!reqRow) { await tgSend(chatId, "That request no longer exists."); return; }

  const regionBadge = reqRow.region === "australia" ? "🇦🇺" : reqRow.region === "india" ? "🇮🇳" : "";

  if (action === "reply") {
    const template = buildTemplate(reqRow);
    await supabase.from("requests").update({
      status: "contacted", contacted_by: actor, contacted_at: new Date().toISOString(), reply_message: template,
    }).eq("id", id);

    const waDigits = String(reqRow.wa || "").replace(/\D/g, "");
    const waLink = waDigits ? `https://wa.me/${waDigits}?text=${encodeURIComponent(template)}` : null;
    const igNote = reqRow.instagram_handle ? `\n\nOr copy this to send via Instagram DM to @${reqRow.instagram_handle}:\n${template}` : "";

    await tgSend(chatId,
      `${regionBadge} Suggested reply for ${reqRow.customer_name || "this customer"}:\n\n"${template}"` +
      (waLink ? `\n\nTap below to open WhatsApp with this pre-filled (you can edit it there before sending).` : "") +
      igNote +
      `\n\nMarked as contacted.`,
      waLink ? { inline_keyboard: [[{ text: "💬 Open WhatsApp", url: waLink }]] } : undefined,
    );
    return;
  }

  if (action === "done" || action === "notdone") {
    const status = action === "done" ? "done" : "not_done";
    await supabase.from("requests").update({
      status, dismissed_by: actor, dismissed_at: new Date().toISOString(),
    }).eq("id", id);
    await tgSend(chatId, `${regionBadge} Request for ${reqRow.customer_name || "customer"} (${reqRow.item_name || "item"}) marked ${status === "done" ? "✅ Done" : "❌ Not Done"} by ${actor}.`);
    return;
  }
}
