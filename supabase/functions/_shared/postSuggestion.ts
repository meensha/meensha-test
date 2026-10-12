// Shared "Suggest a post" logic (social media Stage 2), used both by the
// interactive Maintenance-menu flow in telegram-bot/index.ts and the
// scheduled nudge (post-suggestion-nudge, pg_cron, 2x/week) so a proactive
// push and a manually-triggered suggestion are exactly the same code path —
// not two implementations that can drift apart. India-only by design — see
// feedback_social_media_notifications.md.
//
// Posting itself stays manual (no Graph API publish permission in scope) —
// this ends with an approved caption + image/shot-list, not an auto-post.

// deno-lint-ignore no-explicit-any
type SB = any;
type SendFn = (chatId: number, text: string, keyboard?: unknown) => Promise<void>;
type SaveFn = (supabase: SB, chatId: number, state: string, data: Record<string, unknown>) => Promise<void>;

// The tactic list below is drawn from a real competitor benchmark (Stage 1,
// Oct 2026 initial pass; refreshed Oct 12 2026 against theloomsaree,
// tavissah.sarees and darisabydevashree) of comparable small/solo
// handloom-saree accounts — not generic social-media advice. Pass this to
// every caption prompt so suggestions actually draw on what's working for
// peer-scale accounts, not just tone.
export const POST_BRAND_VOICE = `Meensha is run by two sisters, curating heritage handloom sarees — "Heritage. Handloom." Warm, personal, proud of the weavers, never generic corporate copy.

Real patterns from comparable small/solo handloom-saree accounts (use whichever fits this specific post naturally — don't force all of them in):
- A personal/founder voice sells better than product-only copy — lean into "two sisters" as Meensha's own version of this, the way other accounts lean into their own founder identity.
- Shalini's own story: having seen the breadth of the country across her life, in all its beauty — a genuine, firsthand connection to India's diverse weaving traditions region by region. Use this occasionally where it fits a specific piece's regional origin, not every post.
- Scarcity framing ONLY when the real stock count below is genuinely low (2 or fewer) — never invent urgency that isn't true.
- Tying a post to the current season or an upcoming festival, when it genuinely fits.
- Clear, friendly next-step ("DM to order", "link in bio") rather than leaving it implicit.
- A craft/heritage fact woven in naturally (what makes this weave or region's technique distinct) reads as shareable, not salesy — peer accounts use this to earn saves/shares that reach beyond their own followers, not just likes from existing ones.
- Occasionally invite the customer to tag Meensha in their own photo wearing it ("tag us when it arrives") — every peer account treats customer reposts as its biggest free-reach channel, since it's shown to the buyer's own followers, not just Meensha's.`;

// Returns false (and sends a plain "nothing to suggest" message) instead of
// throwing when there's no eligible item — callers (interactive menu, cron
// nudge) decide what to do next on their own terms.
export async function suggestPost(
  supabase: SB,
  chatId: number,
  callLLM: (supabase: SB, prompt: string) => Promise<string>,
  tgSend: SendFn,
  saveSession: SaveFn,
): Promise<boolean> {
  const { data: skus } = await supabase
    .from("inventory_skus")
    .select("id, name, display_material, display_variant, sale_price, photos, trending, created_at")
    .eq("india_available", true);
  const { data: units } = await supabase.from("inventory_units").select("sku_id").eq("status", "available");
  const availCount: Record<string, number> = {};
  (units ?? []).forEach((u: { sku_id: string }) => { availCount[u.sku_id] = (availCount[u.sku_id] ?? 0) + 1; });
  const fourteenDaysAgo = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
  const candidates = (skus ?? []).filter((s: { id: string; photos?: string[]; trending?: boolean; created_at: string }) =>
    (availCount[s.id] ?? 0) > 0 && (s.photos ?? []).length > 0 && (s.trending || s.created_at >= fourteenDaysAgo)
  );
  if (!candidates.length) {
    await tgSend(chatId, "No Trending or recently-added items with a photo to suggest from right now — tag an item Trending in admin, or add a photo to a new item, then try again.");
    return false;
  }
  const sku = candidates[Math.floor(Math.random() * candidates.length)];

  const { data: events } = await supabase
    .from("popups")
    .select("id, title")
    .eq("status", "upcoming")
    .limit(1);
  const event = events?.[0] ?? null;

  const prompt = `${POST_BRAND_VOICE}\n\nWrite a short Instagram caption (2-4 lines, no hashtags, no markdown) for this item:\nName: ${sku.name}\nMaterial: ${sku.display_material ?? ""}\nVariant: ${sku.display_variant ?? ""}\nPrice: ₹${sku.sale_price}\nReal available stock: ${availCount[sku.id]} piece(s)\n${sku.trending ? "This item is currently trending/selling well." : "This item just arrived — new stock."}\n${event ? `There's an upcoming event "${event.title}" — you may tie the caption to it if it fits naturally, don't force it.` : ""}\n\nReply with ONLY the caption text.`;

  let caption: string;
  try {
    caption = (await callLLM(supabase, prompt)).trim();
  } catch {
    caption = `${sku.name} — ₹${sku.sale_price}. Heritage handloom, handpicked for you.`;
  }

  const data = {
    postDraft: {
      skuId: sku.id,
      skuName: `${sku.name}${sku.display_variant ? " (" + sku.display_variant + ")" : ""}`,
      photo: sku.photos?.[0] ?? null,
      caption,
      eventId: event?.id ?? null,
      eventTitle: event?.title ?? null,
      eventAttached: false,
    },
  };
  await saveSession(supabase, chatId, "maint_postsuggest_active", data);
  await showPostSuggestion(chatId, data, tgSend);
  return true;
}

// deno-lint-ignore no-explicit-any
export async function showPostSuggestion(chatId: number, data: any, tgSend: SendFn) {
  const d = data.postDraft;
  const buttons = [
    [{ text: "🎥 Video", callback_data: "postsuggest:video" }, { text: "🖼️ Use product photo", callback_data: "postsuggest:photo" }],
    [{ text: "🎨 Generate poster", callback_data: "postsuggest:poster" }],
  ];
  if (d.eventTitle) {
    buttons.push([{ text: `${d.eventAttached ? "✅" : "☐"} Attach to event: ${d.eventTitle}`, callback_data: "postsuggest:event:toggle" }]);
  }
  await tgSend(
    chatId,
    `📣 Suggested post — "${d.skuName}"\n\n${d.caption}\n\nReply here to revise it ("shorter", "more playful", "mention the weaver"), or pick a format below.`,
    { inline_keyboard: buttons },
  );
}

export async function handlePostSuggestionText(
  supabase: SB,
  chatId: number,
  // deno-lint-ignore no-explicit-any
  data: any,
  text: string,
  callLLM: (supabase: SB, prompt: string) => Promise<string>,
  tgSend: SendFn,
  saveSession: SaveFn,
) {
  const instruction = text.trim();
  if (!instruction) return;
  const d = data.postDraft;
  const prompt = `${POST_BRAND_VOICE}\n\nHere is a draft Instagram caption:\n"${d.caption}"\n\nRevise it per this instruction: "${instruction}"\n\nKeep it 2-4 lines, no hashtags, no markdown. Reply with ONLY the revised caption.`;
  try {
    d.caption = (await callLLM(supabase, prompt)).trim() || d.caption;
  } catch {
    await tgSend(chatId, "Couldn't revise it just now — try again, or pick a format to keep this version.");
    return;
  }
  await saveSession(supabase, chatId, "maint_postsuggest_active", data);
  await showPostSuggestion(chatId, data, tgSend);
}

export async function finalizePostSuggestion(
  supabase: SB,
  chatId: number,
  // deno-lint-ignore no-explicit-any
  data: any,
  format: "video" | "photo",
  callLLM: (supabase: SB, prompt: string) => Promise<string>,
  tgSend: SendFn,
  saveSession: SaveFn,
  logActivity: (supabase: SB, bot: "india" | "au", chatId: number, action: string, detail?: string) => Promise<void>,
) {
  const d = data.postDraft;
  const eventLine = d.eventAttached && d.eventTitle ? `\n📅 Tied to: ${d.eventTitle}` : "";

  if (format === "photo") {
    await tgSend(
      chatId,
      `✅ Ready to post\n\n${d.caption}${eventLine}\n\n🖼️ Image: ${d.photo ?? "(no photo on file — attach one manually)"}`,
    );
  } else {
    let shotList: string;
    try {
      shotList = (await callLLM(
        supabase,
        `Give a short (3-5 line) Reel shot-list for an Instagram video featuring this saree: "${d.skuName}". Cover length, framing, and one or two shot ideas (e.g. drape in motion, close-up on border work). Plain text, no markdown.`,
      )).trim();
    } catch {
      shotList = "60-90 sec, natural light. Show the drape in motion, then a close-up on the border/work.";
    }
    await tgSend(chatId, `✅ Ready to film\n\n${d.caption}${eventLine}\n\n🎥 Shot list:\n${shotList}`);
  }

  await logActivity(supabase, "india", chatId, "post_suggestion", d.skuName);
  await saveSession(supabase, chatId, "idle", {});
}
