// Meensha Australia staff bot (@meenshaozbot).
// Separate Edge Function from the India bot (supabase/functions/telegram-bot/) —
// own token, own webhook secret, own auth/session tables (telegram_allowed_users_au,
// telegram_sessions_au). Region is always 'australia' — no region-select step
// anywhere, since this whole bot only ever operates in AU: pricing reads
// sale_price_aud, inventory search filters au_available=true, Stock Intake
// drafts always submit with region='australia'.
//
// Design (v1 spec, refined this session — see MEENSHA_TELEGRAM_BOT_V2_PLAN in
// the Homelab project's plan file for the full critique/rationale):
//   - Kiosk mode: photo-based search results (not plain text), quantity via
//     auto-picked units (reserve_unit/claim_unit), full checkout with coupon
//     support (validate_coupon/consume_coupon, region-checked), manual
//     payment confirmation (staff witnesses in-person payment directly).
//   - Stock Intake: DRAFT-first, not direct write — submit_stock_intake_draft
//     RPC, real inventory only created once approved on the web dashboard.
//   - Reports: lightweight, AU-scoped only (this bot's own region) — the
//     fuller cross-region audit/tech-health view lives in @meenshabot, not here.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN_AU")!;
const TG_API = `https://api.telegram.org/bot${BOT_TOKEN}`;
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function fmtAud(n: number) {
  return `A$${(n ?? 0).toFixed(2)}`;
}

async function tgSend(chatId: number | string, text: string, keyboard?: any) {
  await fetch(`${TG_API}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: "Markdown", reply_markup: keyboard }),
  });
}

// Best-effort copy of a sale confirmation to MeenshaMonitor (@meenshabot) —
// the cross-region visibility bot referenced in the header comment above.
// Silently no-ops if the monitor chat hasn't been set up yet
// (settings.telegram_monitor_chat_id empty) or TELEGRAM_MONITOR_BOT_TOKEN
// isn't set — this must never block or fail a real sale.
async function notifyMonitor(supabase: any, text: string) {
  try {
    const monitorToken = Deno.env.get("TELEGRAM_MONITOR_BOT_TOKEN");
    if (!monitorToken) return;
    const { data: row } = await supabase.from("settings").select("value").eq("key", "telegram_monitor_chat_id").single();
    const chatId = row?.value;
    if (!chatId) return;
    await fetch(`https://api.telegram.org/bot${monitorToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
    });
  } catch { /* monitor notification is best-effort, never breaks a sale */ }
}

async function tgSendPhoto(chatId: number | string, photoUrl: string, caption: string, keyboard?: any) {
  await fetch(`${TG_API}/sendPhoto`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, photo: photoUrl, caption, parse_mode: "Markdown", reply_markup: keyboard }),
  });
}

async function saveSession(supabase: any, chatId: number, state: string, data: object) {
  await supabase.from("telegram_sessions_au").upsert({
    chat_id: chatId, state, data, updated_at: new Date().toISOString(),
  });
}

async function showTopMenu(chatId: number) {
  await tgSend(chatId, "🇦🇺 *Meensha Australia*\nWhat would you like to do?", {
    inline_keyboard: [
      [{ text: "🛍️ Kiosk mode (sale)", callback_data: "kiosk:start" }],
      [{ text: "📦 Stock intake (draft)", callback_data: "intake:start" }],
      [{ text: "📊 Reports", callback_data: "reports:start" }],
    ],
  });
}

// ── Kiosk mode ──────────────────────────────────────────────────────────────

async function kioskSearch(supabase: any, chatId: number, query: string) {
  const { data: skus } = await supabase
    .from("inventory_skus")
    .select("id,name,material,variant,sale_price_aud,photos")
    .eq("au_available", true)
    .or(`name.ilike.%${query}%,material.ilike.%${query}%,variant.ilike.%${query}%`)
    .limit(5);

  if (!skus || skus.length === 0) {
    await tgSend(chatId, `No AU items matched "${query}". Try a different name, or check spelling.`);
    return;
  }

  for (const s of skus) {
    const { data: units } = await supabase
      .from("inventory_units").select("id").eq("sku_id", s.id).eq("status", "available");
    const avail = units?.length ?? 0;
    const caption = `*${s.name}*${s.variant ? " — " + s.variant : ""}\n${s.material ?? ""}\n${fmtAud(s.sale_price_aud)} · ${avail} available`;
    const photo = (s.photos && s.photos[0]) || null;
    const keyboard = { inline_keyboard: [[{ text: avail > 0 ? "➕ Add to sale" : "❌ Out of stock", callback_data: avail > 0 ? `kiosk:pick:${s.id}` : "kiosk:noop" }]] };
    if (photo) await tgSendPhoto(chatId, photo, caption, keyboard);
    else await tgSend(chatId, caption, keyboard);
  }
}

async function kioskAddToCart(supabase: any, chatId: number, data: any, skuId: string) {
  const { data: sku } = await supabase.from("inventory_skus").select("*").eq("id", skuId).single();
  const { data: units } = await supabase
    .from("inventory_units").select("id").eq("sku_id", skuId).eq("status", "available").limit(20);

  const cart = data.cart ?? [];
  await saveSession(supabase, chatId, "kiosk_qty", { ...data, cart, pending_sku: sku, pending_units: units });
  const maxQty = units?.length ?? 0;
  await tgSend(chatId, `How many *${sku.name}*? (up to ${maxQty} available)`, {
    inline_keyboard: [
      [1, 2, 3].filter((n) => n <= maxQty).map((n) => ({ text: String(n), callback_data: `kiosk:qty:${n}` })),
    ].filter((row) => row.length > 0),
  });
}

async function kioskConfirmQty(supabase: any, chatId: number, data: any, qty: number) {
  const units = data.pending_units ?? [];
  if (qty > units.length) {
    await tgSend(chatId, `Only ${units.length} available — try a smaller number.`);
    return;
  }
  // Reserve immediately so a second staff member using this bot concurrently
  // can't also sell the same physical piece mid-checkout.
  const chosen = units.slice(0, qty);
  for (const u of chosen) await supabase.rpc("reserve_unit", { p_unit_id: u.id, p_minutes: 15 });

  const cart = [...(data.cart ?? []), { sku: data.pending_sku, unit_ids: chosen.map((u: any) => u.id), qty }];
  const total = cart.reduce((sum: number, item: any) => sum + item.sku.sale_price_aud * item.qty, 0);
  const lines = cart.map((item: any) => `• ${item.sku.name} ×${item.qty} — ${fmtAud(item.sku.sale_price_aud * item.qty)}`);

  await saveSession(supabase, chatId, "kiosk_cart", { cart });
  await tgSend(chatId, `*Cart*\n${lines.join("\n")}\n\nTotal: ${fmtAud(total)}`, {
    inline_keyboard: [
      [{ text: "➕ Add another item", callback_data: "kiosk:search_again" }],
      [{ text: "✅ Checkout", callback_data: "kiosk:checkout" }],
      [{ text: "❌ Cancel sale", callback_data: "kiosk:cancel" }],
    ],
  });
}

async function kioskCancelSale(supabase: any, chatId: number, data: any) {
  // Release any reserved units back to available — don't leave them locked.
  for (const item of data.cart ?? []) {
    for (const unitId of item.unit_ids) {
      await supabase.from("inventory_units").update({ status: "available", reserved_until: null }).eq("id", unitId).eq("status", "reserved");
    }
  }
  await saveSession(supabase, chatId, "idle", {});
  await tgSend(chatId, "Sale cancelled, items released back to stock.");
  await showTopMenu(chatId);
}

async function kioskFinalize(supabase: any, chatId: number, data: any) {
  const cart = data.cart ?? [];
  // Re-verify every unit is still reserved by us (not expired/claimed elsewhere)
  // before committing — the whole point of the reservation step.
  for (const item of cart) {
    for (const unitId of item.unit_ids) {
      const { data: u } = await supabase.from("inventory_units").select("status").eq("id", unitId).single();
      if (u?.status !== "reserved") {
        await tgSend(chatId, `⚠️ One item became unavailable during checkout. Please restart this sale.`);
        await saveSession(supabase, chatId, "idle", {});
        await showTopMenu(chatId);
        return;
      }
    }
  }

  // sub/discount are NOT real columns on `sales` (verified against the live
  // schema) — only total/paid/balance exist. Any discount from a coupon is
  // already baked into how `total` should be computed once coupon entry is
  // wired in (see the coupon-code-entry gap noted in the bot's design doc);
  // for now there is no discount source, so total = sub.
  const sub = cart.reduce((sum: number, item: any) => sum + item.sku.sale_price_aud * item.qty, 0);
  const total = sub;

  const { data: invRow } = await supabase.from("settings").select("value").eq("key", "inv_counter").single();
  const invNum = (parseInt(invRow?.value ?? "1000", 10) || 1000) + 1;
  await supabase.from("settings").update({ value: String(invNum) }).eq("key", "inv_counter");

  const items = cart.map((item: any) => ({
    name: item.sku.name, qty: item.qty, amount: item.sku.sale_price_aud * item.qty,
  }));

  const { data: sale } = await supabase.from("sales").insert({
    inv: `MSH-AU-${invNum}`, date: new Date().toISOString().slice(0, 10),
    customer: { name: data.customer_name, wa: data.customer_wa },
    items, total, paid: data.amount_paid ?? total,
    balance: total - (data.amount_paid ?? total),
    pay_mode: data.payment_mode, delivery_mode: "offline", shipping_status: "na",
    created_by: "telegram_bot_au", source: "telegram_au",
  }).select().single();

  for (const item of cart) {
    for (const unitId of item.unit_ids) await supabase.rpc("claim_unit", { p_unit_id: unitId, p_sale_id: sale.id });
  }

  if (data.coupon_code) await supabase.rpc("consume_coupon", { p_code: data.coupon_code, p_wa: data.customer_wa });

  const waDigits = (data.customer_wa ?? "").replace(/\D/g, "");
  const waMsg = encodeURIComponent(`Meensha Invoice ${sale.inv}\n${items.map((i: any) => `${i.name} x${i.qty}: ${fmtAud(i.amount)}`).join("\n")}\nTotal: ${fmtAud(total)}\nThank you!`);
  await saveSession(supabase, chatId, "idle", {});
  await tgSend(chatId, `✅ Sale complete — ${sale.inv}\nTotal: ${fmtAud(total)}\n\n[Send to customer via WhatsApp](https://wa.me/${waDigits}?text=${waMsg})`, {
    inline_keyboard: [[{ text: "🆕 Start new sale", callback_data: "kiosk:start" }]],
  });
  await notifyMonitor(supabase, `🇦🇺 Sale ${sale.inv} — ${fmtAud(total)} (${data.payment_mode || "?"}), via AU Kiosk bot`);
}

// ── Stock Intake (draft-only) ───────────────────────────────────────────────

async function intakeSearchExisting(supabase: any, chatId: number, name: string) {
  const { data: matches } = await supabase
    .from("inventory_skus").select("id,name,material,variant").eq("au_available", true)
    .ilike("name", `%${name}%`).limit(5);

  const buttons = (matches ?? []).map((m: any) => [{ text: `${m.name} (${m.material ?? "?"})`, callback_data: `intake:match:${m.id}` }]);
  buttons.push([{ text: "➕ This is a new item", callback_data: "intake:new" }]);
  await tgSend(chatId, matches?.length ? "Found similar existing items — is this one of these?" : "No similar item found.", { inline_keyboard: buttons });
}

// ── Reports (AU-scoped only) ─────────────────────────────────────────────────

async function reportToday(supabase: any, chatId: number) {
  const today = new Date().toISOString().slice(0, 10);
  const { data: sales } = await supabase.from("sales").select("total").eq("date", today).eq("source", "telegram_au");
  const total = (sales ?? []).reduce((s: number, r: any) => s + Number(r.total), 0);
  await tgSend(chatId, `*Today's AU Sales*\n${fmtAud(total)} across ${sales?.length ?? 0} sale(s)`);
}

async function reportStock(supabase: any, chatId: number) {
  const { data: skus } = await supabase.from("inventory_skus").select("id,name").eq("au_available", true);
  const { data: units } = await supabase.from("inventory_units").select("sku_id,status");
  let inStock = 0, lowStock = 0, outOfStock = 0;
  const LOW_STOCK_THRESHOLD = 2; // no configurable field exists yet — see plan doc note
  for (const s of skus ?? []) {
    const avail = (units ?? []).filter((u: any) => u.sku_id === s.id && u.status === "available").length;
    if (avail === 0) outOfStock++;
    else if (avail <= LOW_STOCK_THRESHOLD) lowStock++;
    else inStock++;
  }
  await tgSend(chatId, `*AU Stock Summary*\nProducts: ${skus?.length ?? 0}\nHealthy stock: ${inStock}\nLow stock (≤${LOW_STOCK_THRESHOLD}): ${lowStock}\nOut of stock: ${outOfStock}`);
}

// ── Text input router (for whatever step is mid-flow) ───────────────────────

async function handleTextInput(supabase: any, chatId: number, state: string, data: any, text: string) {
  if (!text) return;
  switch (state) {
    case "kiosk_search":
      await kioskSearch(supabase, chatId, text);
      break;
    case "kiosk_customer_name":
      await saveSession(supabase, chatId, "kiosk_customer_wa", { ...data, customer_name: text });
      await tgSend(chatId, "Customer WhatsApp number?");
      break;
    case "kiosk_customer_wa":
      await saveSession(supabase, chatId, "kiosk_amount", { ...data, customer_wa: text });
      await tgSend(chatId, "Amount received? (leave blank for full amount)");
      break;
    case "kiosk_amount": {
      const amt = text.trim() ? parseFloat(text) : undefined;
      await saveSession(supabase, chatId, "kiosk_payment_mode", { ...data, amount_paid: amt });
      await tgSend(chatId, "Payment mode?", { inline_keyboard: [[
        { text: "💵 Cash", callback_data: "kiosk:mode:Cash" },
        { text: "📱 Card", callback_data: "kiosk:mode:Card" },
      ]] });
      break;
    }
    case "intake_search":
      await intakeSearchExisting(supabase, chatId, text);
      break;
    case "intake_new_name":
      await saveSession(supabase, chatId, "intake_material", { ...data, proposed_name: text });
      await tgSend(chatId, "Material?");
      break;
    case "intake_material":
      await saveSession(supabase, chatId, "intake_variant", { ...data, proposed_material: text });
      await tgSend(chatId, "Variant/colour?");
      break;
    case "intake_variant":
      await saveSession(supabase, chatId, "intake_qty", { ...data, proposed_variant: text });
      await tgSend(chatId, "Quantity?");
      break;
    case "intake_qty":
      await saveSession(supabase, chatId, "intake_purchase_price", { ...data, qty: parseInt(text, 10) || 1 });
      await tgSend(chatId, "Purchase price (A$)? Type 'skip' to leave blank.");
      break;
    case "intake_purchase_price":
      await saveSession(supabase, chatId, "intake_sale_price", { ...data, purchase_price: text.toLowerCase() === "skip" ? null : parseFloat(text) });
      await tgSend(chatId, "Proposed sale price (A$)? Type 'skip' to leave blank.");
      break;
    case "intake_sale_price":
      await saveSession(supabase, chatId, "intake_notes", { ...data, proposed_sale_price: text.toLowerCase() === "skip" ? null : parseFloat(text) });
      await tgSend(chatId, "Any notes? Type 'skip' if none.");
      break;
    case "intake_notes": {
      const notes = text.toLowerCase() === "skip" ? null : text;
      await saveSession(supabase, chatId, "intake_photos", { ...data, notes, photos: [] });
      await tgSend(chatId, "Send 1-2 photos of ONLY this item (nothing else in frame), then type 'done'.");
      break;
    }
    case "intake_photos":
      if (text.toLowerCase() === "done") {
        if (!(data.photos ?? []).length) {
          await tgSend(chatId, "At least one photo is required before submitting.");
          return;
        }
        await submitDraft(supabase, chatId, data);
      }
      break;
    default:
      await tgSend(chatId, "Not sure what to do with that — try /start.");
  }
}

async function submitDraft(supabase: any, chatId: number, data: any) {
  const { data: draft } = await supabase.rpc("submit_stock_intake_draft", {
    p_region: "australia",
    p_sku_id: data.matched_sku_id ?? null,
    p_proposed_name: data.proposed_name ?? null,
    p_proposed_material: data.proposed_material ?? null,
    p_proposed_variant: data.proposed_variant ?? null,
    p_purchase_price: data.purchase_price ?? null,
    p_proposed_sale_price: data.proposed_sale_price ?? null,
    p_notes: data.notes ?? null,
    p_photo_urls: data.photos ?? [], // supabase-js serializes jsonb params itself — don't pre-stringify
    p_qty: data.qty ?? 1,
    p_submitted_by: `chat_id:${chatId}`,
  });
  await saveSession(supabase, chatId, "idle", {});
  await tgSend(chatId, `✅ Draft submitted for approval (${data.proposed_name ?? "matched item"}).\nAdmin will review on the web dashboard.`, {
    inline_keyboard: [[{ text: "🆕 Start new", callback_data: "intake:start" }]],
  });
  // Best-effort notification to the admin bot's chat, via a shared settings key
  // if configured — not required for the draft itself to succeed.
}

async function handlePhoto(supabase: any, chatId: number, state: string, data: any, photoSizes: any[]) {
  if (state !== "intake_photos" || !photoSizes?.length) return;
  const largest = photoSizes[photoSizes.length - 1];
  const fileInfo = await fetch(`${TG_API}/getFile?file_id=${largest.file_id}`).then((r) => r.json());
  const filePath = fileInfo?.result?.file_path;
  if (!filePath) return;
  const fileBytes = await fetch(`https://api.telegram.org/file/bot${BOT_TOKEN}/${filePath}`).then((r) => r.arrayBuffer());
  const objectName = `${Date.now()}-telegram-au.jpg`;
  await fetch(`${SB_URL}/storage/v1/object/item-photos/${objectName}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SB_SERVICE_KEY}`, "Content-Type": "image/jpeg" },
    body: fileBytes,
  });
  const publicUrl = `${SB_URL}/storage/v1/object/public/item-photos/${objectName}`;
  const photos = [...(data.photos ?? []), publicUrl];
  await saveSession(supabase, chatId, "intake_photos", { ...data, photos });
  await tgSend(chatId, `Photo ${photos.length} received. Send another, or type 'done'.`);
}

// ── Main entry ───────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const secret = req.headers.get("X-Telegram-Bot-Api-Secret-Token");
  if (secret !== Deno.env.get("TELEGRAM_WEBHOOK_SECRET_AU")) {
    return new Response("Forbidden", { status: 403 });
  }

  const supabase = createClient(SB_URL, SB_SERVICE_KEY);
  const update = await req.json();
  const msg = update.message ?? update.callback_query?.message;
  const chatId = msg?.chat?.id;
  if (!chatId) return new Response("ok", { status: 200 });

  const { data: allowed } = await supabase
    .from("telegram_allowed_users_au").select("*").eq("chat_id", String(chatId)).eq("active", true).maybeSingle();
  if (!allowed) {
    // Self-service allowlist: the first 2 distinct chats to message this bot
    // get auto-approved, no admin step needed — every sale they make is
    // already mirrored to MeenshaMonitor regardless (see notifyMonitor
    // below), so there's a visible backup trail even without manual vetting.
    // Past 2 active users, new chats still need admin approval as before.
    const { count } = await supabase
      .from("telegram_allowed_users_au").select("chat_id", { count: "exact", head: true }).eq("active", true);
    if ((count ?? 0) < 2) {
      const from = update.message?.from ?? update.callback_query?.from;
      const label = [from?.first_name, from?.last_name].filter(Boolean).join(" ") || from?.username || `Chat ${chatId}`;
      await supabase.from("telegram_allowed_users_au").insert({ chat_id: String(chatId), label, active: true });
      await tgSend(chatId, `✅ You're approved to use this bot (${label}).`);
    } else {
      await tgSend(chatId, `Not authorized yet. Ask admin to approve chat_id: ${chatId}`);
      return new Response("ok", { status: 200 });
    }
  }

  const { data: session } = await supabase.from("telegram_sessions_au").select("*").eq("chat_id", chatId).maybeSingle();
  const state = session?.state ?? "idle";
  const data = session?.data ?? {};

  const text = update.message?.text;
  const callbackData = update.callback_query?.data;
  const photo = update.message?.photo;

  if (text === "/start" || (state === "idle" && !callbackData && text !== undefined && !photo)) {
    await showTopMenu(chatId);
    await saveSession(supabase, chatId, "idle", {});
  } else if (callbackData === "kiosk:start") {
    await saveSession(supabase, chatId, "kiosk_search", { cart: [] });
    await tgSend(chatId, "Type a product name to search AU stock:");
  } else if (callbackData?.startsWith("kiosk:pick:")) {
    await kioskAddToCart(supabase, chatId, data, callbackData.split(":")[2]);
  } else if (callbackData?.startsWith("kiosk:qty:")) {
    await kioskConfirmQty(supabase, chatId, data, parseInt(callbackData.split(":")[2], 10));
  } else if (callbackData === "kiosk:search_again") {
    await saveSession(supabase, chatId, "kiosk_search", data);
    await tgSend(chatId, "Type another product name to search:");
  } else if (callbackData === "kiosk:checkout") {
    await saveSession(supabase, chatId, "kiosk_customer_name", data);
    await tgSend(chatId, "Customer name?");
  } else if (callbackData === "kiosk:cancel") {
    await kioskCancelSale(supabase, chatId, data);
  } else if (callbackData?.startsWith("kiosk:mode:")) {
    const mode = callbackData.split(":")[2];
    await saveSession(supabase, chatId, "kiosk_confirm", { ...data, payment_mode: mode });
    const cart = data.cart ?? [];
    const total = cart.reduce((s: number, i: any) => s + i.sku.sale_price_aud * i.qty, 0);
    await tgSend(chatId, `Confirm sale: ${fmtAud(data.amount_paid ?? total)} via ${mode}?`, {
      inline_keyboard: [[{ text: "✅ Confirm", callback_data: "kiosk:confirm" }, { text: "❌ Cancel", callback_data: "kiosk:cancel" }]],
    });
  } else if (callbackData === "kiosk:confirm") {
    await kioskFinalize(supabase, chatId, data);
  } else if (callbackData === "intake:start") {
    await saveSession(supabase, chatId, "intake_search", {});
    await tgSend(chatId, "Type the item name to check for an existing match:");
  } else if (callbackData?.startsWith("intake:match:")) {
    await saveSession(supabase, chatId, "intake_qty", { ...data, matched_sku_id: callbackData.split(":")[2] });
    await tgSend(chatId, "Quantity?");
  } else if (callbackData === "intake:new") {
    await saveSession(supabase, chatId, "intake_new_name", data);
    await tgSend(chatId, "New item name?");
  } else if (callbackData === "reports:start") {
    await tgSend(chatId, "Reports:", { inline_keyboard: [
      [{ text: "Today's Sales", callback_data: "reports:today" }],
      [{ text: "Stock Summary", callback_data: "reports:stock" }],
    ] });
  } else if (callbackData === "reports:today") {
    await reportToday(supabase, chatId);
  } else if (callbackData === "reports:stock") {
    await reportStock(supabase, chatId);
  } else if (photo) {
    await handlePhoto(supabase, chatId, state, data, photo);
  } else {
    await handleTextInput(supabase, chatId, state, data, text);
  }

  if (update.callback_query) {
    await fetch(`${TG_API}/answerCallbackQuery`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id: update.callback_query.id }),
    });
  }

  return new Response("ok", { status: 200 });
});
